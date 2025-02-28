# frozen_string_literal: true

#
# Copyright (C) 2015 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.

require_relative "../../helpers/gradebook_common"
require_relative "../pages/student_grades_page"

describe "gradebook - logged in as a student" do
  include_context "in-process server selenium tests"

  # Helpers
  def backend_group_helper
    Factories::GradingPeriodGroupHelper.new
  end

  def backend_period_helper
    Factories::GradingPeriodHelper.new
  end

  context "when :student_grade_summary_upgrade feature flag is OFF" do
    context "total point displays" do
      before(:once) do
        course_with_student({ active_course: true, active_enrollment: true })
        @teacher = User.create!
        @course.enroll_teacher(@teacher)
        @assignment = @course.assignments.build(points_possible: 20)
        @assignment.publish
        @assignment.grade_student(@student, grade: 10, grader: @teacher)
        @assignment.assignment_group.update(group_weight: 1)
        @course.show_total_grade_as_points = true
        @course.save!
      end

      it 'displays total and "out of" point values' do
        user_session(@student)
        StudentGradesPage.visit_as_student(@course)
        expect(StudentGradesPage.final_grade).to include_text("10")
        expect(StudentGradesPage.final_points_possible).to include_text("10.00 / 20.00")
      end

      it "displays both score and letter grade when course uses a grading scheme" do
        @course.update_attribute :grading_standard_id, 0 # the default
        @course.save!

        user_session(@student)
        StudentGradesPage.visit_as_student(@course)
        expect(f("div.final_grade").text).to eq "Total: 10.00 / 20.00 (F)"
        expect(f("tr.group_total").text).to eq "Assignments\n50%\n10.00 / 20.00"
      end

      it "respects grade dropping rules" do
        ag = @assignment.assignment_group
        ag.update(rules: "drop_lowest:1")
        ag.save!

        undropped = @course.assignments.build(points_possible: 20)
        undropped.publish
        undropped.grade_student(@student, grade: 20, grader: @teacher)
        user_session(@student)
        StudentGradesPage.visit_as_student(@course)
        expect(f("tr#submission_#{@assignment.id}").attribute("title")).to eq "This assignment is dropped and will not be considered in the total calculation"
        expect(f("div.final_grade").text).to eq "Total: 20.00 / 20.00"
        expect(f("tr.group_total").text).to eq "Assignments\n100%\n20.00 / 20.00"
        expect(f("tr#submission_final-grade").text).to eq "Total\n20.00 / 20.00\n20.00 / 20.00"
      end
    end

    context "when testing multiple courses" do
      it "can switch between courses" do
        admin = account_admin_user
        my_student = user_factory(name: "My Student", active_all: true)
        student_courses = Array.new(2) { |i| course_factory(active_course: true, active_all: true, course_name: "SC#{i}") }
        student_courses.each_with_index do |course, index|
          course.enroll_user(my_student, "StudentEnrollment", enrollment_state: "active")
          a = course.assignments.create!(title: "#{course.name} assignment", points_possible: 10)
          a.grade_student(my_student, grade: (10 - index).to_s, grader: admin)
        end

        user_session my_student
        StudentGradesPage.visit_as_student(student_courses[0])
        expect(f(".student_assignment.final_grade").text).to eq "Total\n100%\n10.00 / 10.00"
        expect(f("tr.group_total").text).to eq "Assignments\n100%\n10.00 / 10.00"
        expect(f("tr#submission_final-grade").text).to eq "Total\n100%\n10.00 / 10.00"

        f("#course_select_menu").click
        fj("li:contains('SC1')").click
        fj("button:contains('Apply')").click
        wait_for_ajaximations
        expect(f(".student_assignment.final_grade").text).to eq "Total\n90%\n9.00 / 10.00"
        expect(f("tr.group_total").text).to eq "Assignments\n90%\n9.00 / 10.00"
        expect(f("tr#submission_final-grade").text).to eq "Total\n90%\n9.00 / 10.00"
      end
    end

    context "when testing grading periods" do
      before(:once) do
        account_admin_user({ active_user: true })
        course_with_teacher({ user: @user, active_course: true, active_enrollment: true })
        student_in_course
      end

      context "with one past and one current period" do
        past_period_name = "Past Grading Period"
        current_period_name = "Current Grading Period"
        past_assignment_name = "Past Assignment"
        current_assignment_name = "Current Assignment"

        before do
          # create term
          term = @course.root_account.enrollment_terms.create!
          @course.update(enrollment_term: term)

          # create group and periods
          group = backend_group_helper.create_for_account(@course.root_account)
          term.update_attribute(:grading_period_group_id, group)
          backend_period_helper.create_with_weeks_for_group(group, 4, 2, past_period_name)
          backend_period_helper.create_with_weeks_for_group(group, 1, -3, current_period_name)

          # create assignments
          @course.assignments.create!(due_at: 3.weeks.ago, title: past_assignment_name)
          @course.assignments.create!(due_at: 1.week.from_now, title: current_assignment_name)

          # go to student grades page
          user_session(@teacher)
          StudentGradesPage.visit_as_teacher(@course, @student)
        end

        it "only shows assignments that belong to the selected grading period", priority: "1" do
          StudentGradesPage.select_period_by_name(past_period_name)
          expect_new_page_load { StudentGradesPage.click_apply_button }
          expect(StudentGradesPage.assignment_titles).to include(past_assignment_name)
          expect(StudentGradesPage.assignment_titles).not_to include(current_assignment_name)
        end
      end
    end
  end

  context "when student_grade_summary_upgrade is enabled" do
    before(:once) do
      # enable the feature flag
      Account.site_admin.enable_feature! :student_grade_summary_upgrade

      # Create a course with grading periods, but no assignment grades
      course_with_student({ active_course: true, active_enrollment: true })
      @second_student = @student
      student_in_course(course: @course, active_all: true)
      teacher_in_course(course: @course, active_all: true)
      @current_period_name = "Current Grading Period"
      @past_period_name = "Past Grading Period"
      @all_grading_periods = "All Grading Periods"

      # create term
      term = @course.root_account.enrollment_terms.create!
      @course.update(enrollment_term: term)

      # create grading_period_group and grading_periods
      grading_period_group = backend_group_helper.create_for_account(@course.root_account)
      grading_period_group.weighted = true
      grading_period_group.update(display_totals_for_all_grading_periods: true, weighted: true)
      grading_period_group.save!
      term.update_attribute(:grading_period_group_id, grading_period_group)
      @current_period = backend_period_helper.create_with_weeks_for_group(grading_period_group, 1, -3, @current_period_name)
      @current_period.update(weight: 75)
      @current_period.save
      @past_period = backend_period_helper.create_with_weeks_for_group(grading_period_group, 5, 2, @past_period_name)
      @past_period.update(weight: 25)
      @past_period.save

      # Create assignment groups and drop rules
      group_1 = @course.assignment_groups.create!(name: "Group 1", group_weight: 25)
      group_1.update(rules: "drop_lowest:1")
      group_2 = @course.assignment_groups.create!(name: "Group 2", group_weight: 75)
      group_2.update(rules: "drop_lowest:1")

      # create assignments in past grading period
      @assignment_1 = @course.assignments.create!(due_at: 3.weeks.ago, title: "assignment 1 (past period)", grading_type: "points", points_possible: 100, assignment_group: group_1)
      @assignment_2 = @course.assignments.create!(due_at: 3.weeks.ago, title: "assignment 2 (past period)", grading_type: "points", points_possible: 1000, assignment_group: group_1)
      @assignment_3 = @course.assignments.create!(due_at: 3.weeks.ago, title: "assignment 3 (past period)", grading_type: "points", points_possible: 10, assignment_group: group_1)
      @assignment_4 = @course.assignments.create!(due_at: 3.weeks.ago, title: "assignment 4 (past period)", grading_type: "points", points_possible: 10, assignment_group: group_2)
      @assignment_5 = @course.assignments.create!(due_at: 3.weeks.ago, title: "assignment 5 (past period)", grading_type: "points", points_possible: 10, assignment_group: group_2)

      # Create assignments in current grading period
      @assignment_6 = @course.assignments.create!(due_at: 1.week.from_now, title: "assignment 6 (current period)", grading_type: "points", points_possible: 10, assignment_group: group_2)
      @assignment_7 = @course.assignments.create!(due_at: 1.week.from_now, title: "assignment 7 (current period)", grading_type: "points", points_possible: 10, assignment_group: group_2)
      @assignment_8 = @course.assignments.create!(due_at: 1.week.from_now, title: "assignment 8 (current period)", grading_type: "points", points_possible: 100, assignment_group: group_2)
      @assignment_9 = @course.assignments.create!(due_at: 1.week.from_now, title: "assignment 9 (current period)", grading_type: "points", points_possible: 10, assignment_group: group_1)
      @assignment_10 = @course.assignments.create!(due_at: 1.week.from_now, title: "assignment 10 (current period)", grading_type: "points", points_possible: 10, assignment_group: group_1)

      # Create assignment with no due date
      @assignment_11 = @course.assignments.create!(title: "assignment 11 (no due date)", grading_type: "points", points_possible: 10)

      # Create an override so @student has past_assignment_5 in the current period
      create_adhoc_override_for_assignment(@assignment_5, @student, due_at: 1.week.from_now)
    end

    context "when viewing ungraded assignments" do
      # What a student would see if they had no graded submissions

      it "correctly displays all grading periods" do
        # Testing the following: N/A, 0%, correct assignment groups
        user_session(@student)
        StudentGradesPage.visit_as_student(@course)

        # Select the all grading periods option
        f("#grading_period_select_menu").click
        fj("li:contains('#{@all_grading_periods}')").click
        fj("button:contains('Apply')").click
        wait_for_ajaximations

        # ------- Verify output when "calculate based only on graded assignments" is checked -------

        # Verify the number of assignments is correct
        expect(ff("tr[data-testid='assignment-row']").length).to eq 11

        # Verify that the correct assignments are being dropped
        # TODO: VICE-3636 - FIX it so in this case dropped assignments no longer show, then uncomment
        # expect(f("body")).not_to contain_jqcss("tr:contains('Dropped')")

        # Verify that the 2 grading period rows have the correct values
        # TODO: VICE-3638 FIX it so that the points possible is correct in this case
        # expect(f("tr[data-testid='gradingPeriod-#{@past_period.id}']").text).to eq "Past Grading Period N/A 0.00/0.00"
        # expect(f("tr[data-testid='gradingPeriod-#{@current_period.id}']").text).to eq "Current Grading Period N/A 0.00/0.00"

        # Verify that the total is correct
        # TODO: VICE-3594 FIX the total_row in this case so that it appears correctly, instead of N/A it should have 0%, then uncomment this code
        # expect(f("tr[data-testid='total_row']").text).to eq "Total 0%"

        # ------- Verify output when "calculate based only on graded assignments" is unchecked -------

        # Check the "calculate based only on graded assignments" option
        f("#only_consider_graded_assignments_wrapper").click

        # Verify that the correct assignments are being dropped
        # TODO: VICE-3621 FIX so that dropped assignments are correct in this case
        # dropped_assignments = ffj("tr[data-testid='assignment-row']::contains('Dropped')")
        # expect(dropped_assignments.length).to eq 3
        # dropped_assignments_text = dropped_assignments.map(&:text)
        # expect(dropped_assignments_text.any? { |str| str.include?(@assignment_3.title) }).to be true
        # expect(dropped_assignments_text.any? { |str| str.include?(@assignment_8.title) }).to be true
        # expect(dropped_assignments_text.any? { |str| str.include?(@assignment_11.title) }).to be true

        # Verify that the 2 group rows have the correct values
        # TODO: VICE-3639 FIX it so that 0% is displayed instead of NaN and the correct points possible is displayed, then uncomment
        # expect(f("tr[data-testid='gradingPeriod-#{@past_period.id}']").text).to eq "Past Grading Period 0% 0.00/1,110.00"
        # expect(f("tr[data-testid='gradingPeriod-#{@current_period.id}']").text).to eq "Current Grading Period 0% 0.00/50.00"

        # Verify that the total is correct
        # TODO: VICE-3594 FIX so that the correct info is displayed, 0%, then uncomment
        # expect(f("tr[data-testid='total_row']").text).to eq "Total 0%
      end

      it "correctly displays all past grading period" do
        skip "VICE-3642"
        # Testing the following: N/A, 0%, correct assignment groups
        user_session(@student)
        StudentGradesPage.visit_as_student(@course)

        # Select the all grading periodss option
        f("#grading_period_select_menu").click
        fj("li:contains('#{@past_period_name}')").click
        fj("button:contains('Apply')").click
        wait_for_ajaximations

        # ------- Verify output when "calculate based only on graded assignments" is checked -------

        # Verify the number of assignments is correct
        # TODO: VICE-3620 FIX it so that the correct number of assignments is displayed, then uncomment
        # expect(ff("tr[data-testid='assignment-row']").length).to eq 4

        # Verify that the correct assignments are being dropped
        # TODO: VICE-3636 FIX it so in this case dropped assignments no longer show, then uncomment
        # expect(f("body")).not_to contain_jqcss("tr:contains('Dropped')")

        # Verify that the 2 group rows have the correct values
        expect(f("tr[data-testid='agtotal-Group 1']").text).to eq "Group 1 N/A 0.00/0.00"
        expect(f("tr[data-testid='agtotal-Group 2']").text).to eq "Group 2 N/A 0.00/0.00"

        # Verify that the total is correct
        # TODO: VICE-3636 FIX the total_row in this case so that it appears correctly, points possible and set NaN to N/A, then uncomment this code
        # expect(f("tr[data-testid='total_row']").text).to eq "Total N/A 0.00/0.00"

        # ------- Verify output when "calculate based only on graded assignments" is unchecked -------

        # Check the "calculate based only on graded assignments" option
        f("#only_consider_graded_assignments_wrapper").click

        # Verify that the correct assignments are being dropped
        # TODO: VICE-3594 FIX it so that the correct assignments are being dropped
        # dropped_assignments = ffj("tr[data-testid='assignment-row']::contains('Dropped')")
        # expect(dropped_assignments.length).to eq 1
        # dropped_assignments_text = dropped_assignments.map(&:text)
        # expect(dropped_assignments_text.any? { |str| str.include?(@assignment_3.title) }).to be true

        # Verify that the 2 group rows have the correct values
        # TODO: VICE-3594 FIX it so that 0% is displayed instead of NaN, then uncomment
        # expect(f("tr[data-testid='agtotal-Group 1']").text).to eq "Group 1 0% 0.00/1,100.00"
        # expect(f("tr[data-testid='agtotal-Group 2']").text).to eq "Group 2 0% 0.00/10.00"

        # Verify that the total is correct
        # TODO: VICE-3594 FIX so that the correct info is displayed 0% and points possible, then uncomment
        # expect(f("tr[data-testid='total_row']").text).to eq "Total 0% 0.00/1,110.00"
      end

      it "correctly displays current grading period" do
        skip "VICE-3642"
        # Testing the following: N/A, 0%, correct assignment groups
        user_session(@student)
        StudentGradesPage.visit_as_student(@course)

        # ------- Verify output when "calculate based only on graded assignments" is checked -------

        # Verify the number of assignments is correct
        expect(ff("tr[data-testid='assignment-row']").length).to eq 7

        # Verify that the correct assignments are being dropped
        # TODO: VICE-3636 FIX it so in this case dropped assignments no longer show, then uncomment
        # expect(f("body")).not_to contain_jqcss("tr:contains('Dropped')")

        # Verify that the 2 group rows have the correct values
        expect(f("tr[data-testid='agtotal-Group 1']").text).to eq "Group 1 N/A 0.00/0.00"
        expect(f("tr[data-testid='agtotal-Group 2']").text).to eq "Group 2 N/A 0.00/0.00"

        # Verify that the total is correct
        # TODO: VICE-3594 FIX the total_row in this case so that it appears correctly, points possible and remove the % from NaN, then uncomment this code
        # expect(f("tr[data-testid='total_row']").text).to eq "Total NaN 0.00/0.00"

        # ------- Verify output when "calculate based only on graded assignments" is unchecked -------

        # Check the "calculate based only on graded assignments" option
        f("#only_consider_graded_assignments_wrapper").click

        # Verify that the correct assignments are being dropped
        dropped_assignments = ffj("tr[data-testid='assignment-row']::contains('Dropped')")
        expect(dropped_assignments.length).to eq 2
        dropped_assignments_text = dropped_assignments.map(&:text)
        expect(dropped_assignments_text.any? { |str| str.include?(@assignment_8.title) }).to be true
        expect(dropped_assignments_text.any? { |str| str.include?(@assignment_11.title) }).to be true

        # Verify that the 2 group rows have the correct values
        # TODO: VICE-3594 FIX it so that 0% is displayed instead of NaN, then uncomment
        # expect(f("tr[data-testid='agtotal-Group 1']").text).to eq "Group 1 0% 0.00/20.00"
        # expect(f("tr[data-testid='agtotal-Group 2']").text).to eq "Group 2 0% 0.00/30.00"

        # Verify that the total is correct
        # TODO: VICE-3594 FIX so that the correct info is displayed 0% and points possible, then uncomment
        # expect(f("tr[data-testid='total_row']").text).to eq "Total 0% 0.00/50.00"
      end
    end

    context "when viewing partially graded courses" do
      # What a student would see mid-course when some submissions are graded and others are not
      before(:once) do
        # Grade assignments that have no submission
        @assignment_8.grade_student(@student, grade: 8, grader: @teacher)
        @assignment_9.grade_student(@student, grade: 11, grader: @teacher)

        # Excuse an assignment
        @assignment_7.grade_student(@student, excuse: true, grader: @teacher)

        # Add submission, as student that is not graded
        @assignment_5.submit_homework(@student, { body: "blah" })
        @assignment_10.submit_homework(@student, { body: "blah" })
      end

      it "correctly displays all grading periods" do
        # Testing the following:
        # correct dropped assignments, correct period totals, correct values with the "calculate based only on graded assignments" option, correct assignments in the correct grading period, assignment date overrides, grading period weight, assignment group weight
        user_session(@student)
        StudentGradesPage.visit_as_student(@course)

        # Select the all grading periods option
        f("#grading_period_select_menu").click
        fj("li:contains('#{@all_grading_periods}')").click
        fj("button:contains('Apply')").click
        wait_for_ajaximations

        # ------- Verify output when "calculate based only on graded assignments" is checked -------

        # Verify the number of assignments is correct
        expect(ff("tr[data-testid='assignment-row']").length).to eq 11

        # Verify that the correct assignments are being dropped
        # TODO: FIX VICE-3636 it so the correct assignments are dropped, then uncomment
        # dropped_assignments = ffj("tr[data-testid='assignment-row']:contains('Dropped'), tr[data-testid='assignment-row']:contains('Excused')")
        # expect(dropped_assignments.length).to eq 1
        # dropped_assignments_text = dropped_assignments.map(&:text)
        # expect(dropped_assignments_text.any? { |str| str.include?(@assignment_7.title) }).to be true

        # Verify that the 2 grading period rows have the correct values
        # TODO: FIX VICE-3638 so the correct points possible is shown
        # expect(f("tr[data-testid='gradingPeriod-#{@past_period.id}']").text).to eq "Past Grading Period N/A 0.00/0.00"
        # expect(f("tr[data-testid='gradingPeriod-#{@current_period.id}']").text).to eq "Current Grading Period 17.27% 19.00/110.00"

        # Verify that the total is correct
        # TODO: VICE-3594 FIX it so that the total is correct, then uncomment
        # expect(f("tr[data-testid='total_row']").text).to eq "Total 17.27%"

        # ------- Verify output when "calculate based only on graded assignments" is unchecked -------

        # Check the "calculate based only on graded assignments" option
        f("#only_consider_graded_assignments_wrapper").click

        # Verify that the correct assignments are being dropped
        # TODO: VICE-3637 FIX it so that the correct assignments are dropped ( assignment_6)
        dropped_assignments = ffj("tr[data-testid='assignment-row']:contains('Dropped'), tr[data-testid='assignment-row']:contains('Excused')")
        expect(dropped_assignments.length).to eq 4
        dropped_assignments_text = dropped_assignments.map(&:text)
        expect(dropped_assignments_text.any? { |str| str.include?(@assignment_3.title) }).to be true
        # expect(dropped_assignments_text.any? { |str| str.include?(@assignment_6.title) }).to be true
        expect(dropped_assignments_text.any? { |str| str.include?(@assignment_7.title) }).to be true
        expect(dropped_assignments_text.any? { |str| str.include?(@assignment_11.title) }).to be true

        # Verify that the 2 group rows have the correct values
        # TODO: VICE-3639
        # expect(f("tr[data-testid='gradingPeriod-#{@past_period.id}']").text).to eq "Past Grading Period 0% 0.00/1,110.00"
        # expect(f("tr[data-testid='gradingPeriod-#{@current_period.id}']").text).to eq "Current Grading Period 14.62% 19.00/130.00"

        # Verify that the total is correct
        # TODO: VICE-3594 FIX
        # expect(f("tr[data-testid='total_row']").text).to eq "Total 10.96%
      end

      it "correctly displays current grading period" do
        # Testing the following:
        # correct dropped assignments, correct period totals, correct values with the "calculate based only on graded assignments" option, correct assignments in the correct grading period, assignment date overrides, grading period weight, assignment group weight
        user_session(@student)
        StudentGradesPage.visit_as_student(@course)

        # ------- Verify output when "calculate based only on graded assignments" is checked -------

        # Verify the number of assignments is correct
        expect(ff("tr[data-testid='assignment-row']").length).to eq 7

        # Verify that the correct assignments are being dropped
        # TODO: VICE-3636 FIX it so only one assignment is dropped here
        # dropped_assignments = ffj("tr[data-testid='assignment-row']:contains('Dropped'), tr[data-testid='assignment-row']:contains('Excused')")
        # expect(dropped_assignments.length).to eq 1
        # dropped_assignments_text = dropped_assignments.map(&:text)
        # expect(dropped_assignments_text.any? { |str| str.include?(@assignment_7.title) }).to be true

        # Verify that the 2 group rows have the correct values
        # TODO: VICE-3594 FIX group-2 so that the correct values appear
        expect(f("tr[data-testid='agtotal-Group 1']").text).to eq "Group 1 110.00% 11.00/10.00"
        # expect(f("tr[data-testid='agtotal-Group 2']").text).to eq "Group 2 8.00% 8.00/10.00"

        # Verify that the total is correct
        # TODO: VICE-3594 FIX it so that the points possible shows
        # expect(f("tr[data-testid='total_row']").text).to eq "Total 60% 12.00/20.00"

        # ------- Verify output when "calculate based only on graded assignments" is unchecked -------

        # Check the "calculate based only on graded assignments" option
        f("#only_consider_graded_assignments_wrapper").click

        # Verify that the correct assignments are being dropped
        # TODO: VICE-3637 FIX it so that the correct assignments are dropped
        dropped_assignments = ffj("tr[data-testid='assignment-row']:contains('Dropped'), tr[data-testid='assignment-row']:contains('Excused')")
        expect(dropped_assignments.length).to eq 3
        # dropped_assignments_text = dropped_assignments.map(&:text)
        # expect(dropped_assignments_text.any? { |str| str.include?(@assignment_6.title) }).to be true
        # expect(dropped_assignments_text.any? { |str| str.include?(@assignment_7.title) }).to be true
        # expect(dropped_assignments_text.any? { |str| str.include?(@assignment_11.title) }).to be true

        # Verify that the 2 group rows have the correct values
        # TODO: VICE-3594 FIX it so that the percentages are correct
        # expect(f("tr[data-testid='agtotal-Group 1']").text).to eq "Group 1 55.00% 11.00/20.00"
        # expect(f("tr[data-testid='agtotal-Group 2']").text).to eq "Group 2 7.27% 8.00/110.00"

        # Verify that the total is correct
        # TODO: VICE-3594 FIX it so that the totals are correct
        # expect(f("tr[data-testid='total_row']").text).to eq "Total 14.62% 19.00/130.00"
      end
    end
  end

  context "when student is quantitative data restricted" do
    before do
      course_with_teacher(name: "Dedicated Teacher", active_course: true, active_user: true)
      course_with_student(course: @course, name: "Hardworking Student", active_all: true)

      # truthy feature flag
      Account.default.enable_feature! :restrict_quantitative_data

      # truthy setting
      Account.default.settings[:restrict_quantitative_data] = { value: true, locked: true }
      Account.default.save!
      @course.restrict_quantitative_data = true
      @course.save!
    end

    it "does not show quantitative data" do
      future_period_name = "Future Grading Period"
      current_period_name = "Current Grading Period"
      future_assignment_name = "Future Assignment"
      current_assignment_name = "Current Assignment"

      # create term
      term = @course.root_account.enrollment_terms.create!
      @course.update(enrollment_term: term)

      # create group and periods
      group = backend_group_helper.create_for_account(@course.root_account)
      group.update(display_totals_for_all_grading_periods: true)
      group.save!
      term.update_attribute(:grading_period_group_id, group)
      future_period = backend_period_helper.create_with_weeks_for_group(group, -8, -12, future_period_name)
      current_period = backend_period_helper.create_with_weeks_for_group(group, 1, -3, current_period_name)

      # create assignments
      future_assignment = @course.assignments.create!(due_at: 10.weeks.from_now, title: future_assignment_name, grading_type: "points", points_possible: 10)
      current_assignment = @course.assignments.create!(due_at: 1.week.from_now, title: current_assignment_name, grading_type: "points", points_possible: 10)

      future_assignment.grade_student(@student, grade: "10", grader: @teacher)
      current_assignment.grade_student(@student, grade: "8", grader: @teacher)

      user_session(@student)
      StudentGradesPage.visit_as_student(@course)
      ffj("tr:contains('Assignments')")

      current_assignment_selector = "tr:contains('#{current_assignment_name}')"
      future_assignment_selector = "tr:contains('#{future_assignment_name}')"

      # the all the grades and grading period selected is based on current period
      expect(f("#grading_period_select_menu").attribute(:value)).to eq current_period_name
      expect(f("div.final_grade").text).to eq "Total: B-"
      expect(fj(current_assignment_selector).text).to include "GRADED\nB-\nYour grade has been updated"
      expect(f("tr[data-testid='agtotal-Assignments']").text).to eq "Assignments B-"
      expect(f("tr[data-testid='total_row']").text).to eq "Total B-"
      expect(f("body")).not_to contain_jqcss(future_assignment_selector)

      # switch to future grading period and check that everything is based on the future period
      f("#grading_period_select_menu").click
      fj("li:contains('#{future_period_name}')").click
      fj("button:contains('Apply')").click
      wait_for_ajaximations
      expect(f("div.final_grade").text).to eq "Total: A"
      expect(fj(future_assignment_selector).text).to include "GRADED\nA\nYour grade has been updated"
      expect(f("tr[data-testid='agtotal-Assignments']").text).to eq "Assignments A"
      expect(f("tr[data-testid='total_row']").text).to eq "Total A"
      expect(f("body")).not_to contain_jqcss(current_assignment_selector)

      # switch to all grading periods and verify everything is based on all periods
      f("#grading_period_select_menu").click
      fj("li:contains('All Grading Periods')").click
      fj("button:contains('Apply')").click
      wait_for_ajaximations

      expect(fj(future_assignment_selector).text).to include "GRADED\nA\nYour grade has been updated"
      expect(fj(current_assignment_selector).text).to include "GRADED\nB-\nYour grade has been updated"

      # Make sure the grading period totals show because display_totals_for_all_grading_periods is true
      expect(fj("tr[data-testid='gradingPeriod-#{future_period.id}']").text).to eq "Future Grading Period A"
      expect(fj("tr[data-testid='gradingPeriod-#{current_period.id}']").text).to eq "Current Grading Period B-"

      group.update(display_totals_for_all_grading_periods: false)
      group.save!

      StudentGradesPage.visit_as_student(@course)

      f("#grading_period_select_menu").click
      fj("li:contains('All Grading Periods')").click
      fj("button:contains('Apply')").click
      wait_for_ajaximations

      # Make sure the grading period totals aren't shown because display_totals_for_all_grading_periods was changed to false
      expect(f("body")).not_to contain_jqcss("tr[data-testid='gradingPeriod-#{future_period.id}']")
      expect(f("body")).not_to contain_jqcss("tr[data-testid='gradingPeriod-#{current_period.id}']")
    end

    it "does not show assignment group total when no assignments are a part of the group" do
      course_with_student(course: @course, name: "Hardworking Student", active_all: true)
      group_1 = @course.assignment_groups.create!(name: "Group 1", group_weight: 50)
      group_2 = @course.assignment_groups.create!(name: "Group 2", group_weight: 50)

      assignment_1 = @course.assignments.create!(due_at: 1.week.from_now, title: "Assignment 1", assignment_group: group_1, grading_type: "points", points_possible: 10)
      assignment_2 = @course.assignments.create!(due_at: 1.week.from_now, title: "Assignment 2", assignment_group: group_1, grading_type: "points", points_possible: 10)

      assignment_1.grade_student(@student, grade: "10", grader: @teacher)
      assignment_2.grade_student(@student, grade: "8", grader: @teacher)

      user_session(@student)
      StudentGradesPage.visit_as_student(@course)

      expect(f("tr[data-testid='agtotal-#{group_1.name}']")).to be_displayed
      expect(f("body")).not_to contain_jqcss("tr[data-testid='agtotal-#{group_2.name}']")
    end

    it "displays N/A in the total sidebar when no asignments have been graded" do
      course_with_teacher(name: "Dedicated Teacher", active_course: true, active_user: true)
      course_with_student(course: @course, name: "Hardworking Student", active_all: true)
      @course.restrict_quantitative_data = true
      @course.save!
      @course.assignments.create!(due_at: 1.week.from_now, title: "Current Assignment", grading_type: "points", points_possible: 10)
      user_session(@student)
      get "/courses/#{@course.id}/grades/#{@student.id}"

      expect(f(".final_grade").text).to eq("Total: N/A")
    end
  end
end
