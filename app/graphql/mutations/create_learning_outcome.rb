# frozen_string_literal: true

#
# Copyright (C) 2020 - present Instructure, Inc.
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
#

class Mutations::CreateLearningOutcome < Mutations::BaseMutation
  graphql_name "CreateLearningOutcome"

  # input arguments
  argument :group_id, ID, required: true, prepare: GraphQLHelpers.relay_or_legacy_id_prepare_func("LearningOutcomeGroup")
  argument :title, String, required: true
  argument :description, String, required: false
  argument :display_name, String, required: false
  argument :vendor_guid, String, required: false
  argument :calculation_method, String, required: false
  argument :calculation_int, Integer, required: false
  argument :rubric_criterion, Types::RubricCriterionInputType, required: false

  field :learning_outcome, Types::LearningOutcomeType, null: true

  def resolve(input:)
    outcome_group = learning_outcome_group(input)

    outcome_input = attrs(input, outcome_group)

    record = LearningOutcome.new(context: outcome_group.context, **outcome_input)
    check_permission(record)
    return errors_for(record) unless record.save

    outcome_group.add_outcome(record)
    { learning_outcome: record }
  end

  private

  def learning_outcome_group(input)
    LearningOutcomeGroup.active.find_by(id: input[:group_id]).tap do |group|
      raise GraphQL::ExecutionError, I18n.t("group not found") if group.nil?
    end
  end

  def check_permission(outcome)
    raise GraphQL::ExecutionError, I18n.t("insufficient permission") unless outcome.grants_right? current_user, :create
  end

  def attrs(input, context)
    outcome_input = input.to_h.slice(:title, :display_name, :description, :vendor_guid)
    ratings_input = input.to_h.slice(:calculation_method, :calculation_int, :rubric_criterion)

    if ratings_input.count.positive?
      raise GraphQL::ExecutionError, I18n.t("individual ratings data input with invidual_outcome_rating_and_calculation FF disabled") unless context.root_account.feature_enabled?(:individual_outcome_rating_and_calculation)
      raise GraphQL::ExecutionError, I18n.t("individual ratings data input with acount_level_mastery_scale FF enabled") if context.root_account.feature_enabled?(:account_level_mastery_scales)
    end

    outcome_input.merge(ratings_input)
  end
end
