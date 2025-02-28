/*
 * Copyright (C) 2023 - present Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import React, {Fragment, ChangeEvent, useState, useImperativeHandle} from 'react'
import shortid from '@canvas/shortid'

import {useScope as useI18nScope} from '@canvas/i18n'
import {View} from '@instructure/ui-view'
import {TextInput} from '@instructure/ui-text-input'
import {ScreenReaderContent} from '@instructure/ui-a11y-content'
// @ts-expect-error -- TODO: remove once we're on InstUI 8
import {RadioInputGroup, RadioInput} from '@instructure/ui-radio-input'
import numberHelper from '@canvas/i18n/numberHelper'

import {GradingSchemeDataRowInput} from './GradingSchemeDataRowInput'
import {GradingSchemeDataRow} from '../../../gradingSchemeApiModel'
import {GradingSchemeValidationAlert} from './GradingSchemeValidationAlert'
import {gradingSchemeIsValid} from './validations/gradingSchemeValidations'
import {roundToTwoDecimalPlaces, roundToFourDecimalPlaces} from '../../helpers/roundDecimalPlaces'

const I18n = useI18nScope('GradingSchemeManagement')

export interface ComponentProps {
  initialFormDataByInputType: {
    percentage: GradingSchemeEditableData
    points: GradingSchemeEditableData
  }
  onSave: (updatedGradingSchemeData: GradingSchemeEditableData) => any
  pointsBasedGradingSchemesFeatureEnabled: boolean
  schemeInputType: 'percentage' | 'points'
}
export interface GradingSchemeEditableData {
  title: string
  data: GradingSchemeDataRow[]
  scalingFactor: number
  pointsBased: boolean
}

export type GradingSchemeInputHandle = {
  savePressed: () => void
}

/**
 * Form input for creating or updating GradingSchemes.
 *
 * This form input component is an imperative component because its
 * 'save' button is located in an external component (such as a modal
 * action button row).  This component handles all form validation
 * prior to calling the parent's onSave callback
 *
 * @param initialFormData Data to set as initial default values for the form
 * @constructor
 */

export const GradingSchemeInput = React.forwardRef<GradingSchemeInputHandle, ComponentProps>(
  (
    {initialFormDataByInputType, schemeInputType, onSave, pointsBasedGradingSchemesFeatureEnabled},
    ref
  ) => {
    interface GradingSchemeInputState {
      title: string
      rows: GradingSchemeRowState[]
      scalingFactor: number
      pointsBased: boolean
    }

    interface GradingSchemeRowState {
      uniqueId: string
      letterGrade: string
      minRangeDisplay: string
      maxRangeDisplay: string
    }

    const [showAlert, setShowAlert] = useState<boolean>(false)

    const formStateByType = {
      percentage: initializeFormState(initialFormDataByInputType.percentage),
      points: initializeFormState(initialFormDataByInputType.points),
    }

    const [formState, setFormState] = useState<GradingSchemeInputState>(
      schemeInputType === 'points' ? formStateByType.points : formStateByType.percentage
    )

    function decimalRangeToDisplayString(percentageValue: number, displayScalingFactor: number) {
      return String(roundToTwoDecimalPlaces(percentageValue * displayScalingFactor))
    }

    function rangeDisplayStringToDecimal(rangeString: string, displayScalingFactor: number) {
      const inputVal = numberHelper.parse(rangeString)
      if (Number.isNaN(Number(inputVal))) return NaN
      return roundToFourDecimalPlaces(roundToTwoDecimalPlaces(inputVal) / displayScalingFactor)
    }

    function initializeFormState(formInput: GradingSchemeEditableData): GradingSchemeInputState {
      const scalingFactorDisplay = formInput.scalingFactor * (formInput.pointsBased ? 1 : 100)
      return {
        title: formInput.title,
        // deep clone the template's row data. (we don't want to modify the provided data by reference)
        rows: formInput.data.map((dataRow, idx, arr) => {
          return {
            uniqueId: shortid(),
            letterGrade: dataRow.name,
            minRangeDisplay: decimalRangeToDisplayString(dataRow.value, scalingFactorDisplay),
            maxRangeDisplay: decimalRangeToDisplayString(
              idx === 0 ? 1 : arr[idx - 1].value,
              scalingFactorDisplay
            ),
            pointsBased: formInput.pointsBased,
          }
        }),
        scalingFactor: scalingFactorDisplay,
        pointsBased: formInput.pointsBased,
      }
    }

    useImperativeHandle(ref, () => ({
      savePressed: () => {
        const data = formState.rows.map(row => ({
          name: row.letterGrade,
          value: rangeDisplayStringToDecimal(row.minRangeDisplay, formState.scalingFactor),
        }))

        const dataToSave = {
          title: formState.title,
          data,
          scalingFactor: formState.scalingFactor / (formState.pointsBased ? 1 : 100),
          pointsBased: formState.pointsBased,
        }
        const isValid = gradingSchemeIsValid(dataToSave)

        setShowAlert(!isValid)
        if (isValid) {
          onSave(dataToSave)
        }
      },
    }))

    const handlePointsBasedChanged = (newValue: string) => {
      if (formState.pointsBased && newValue === 'percentage') {
        setFormState(
          initializeFormState({...initialFormDataByInputType.percentage, title: formState.title})
        )
      } else if (!formState.pointsBased && newValue === 'points') {
        setFormState(
          initializeFormState({...initialFormDataByInputType.points, title: formState.title})
        )
      }
    }

    const changeRowLetterGrade = (rowIndex: number, newLetterGrade: string) => {
      const updatedScheme = {
        ...formState,
      }
      updatedScheme.rows[rowIndex].letterGrade = newLetterGrade
      setFormState(updatedScheme)
    }

    const handleBlurRowLowRange = (rowIndex: number, lowRangeInputAsString: string) => {
      const lowRange = numberHelper._parseNumber(lowRangeInputAsString)
      let lowRangeAsString = lowRangeInputAsString
      if (!Number.isNaN(lowRange)) {
        lowRangeAsString = String(roundToTwoDecimalPlaces(lowRange))
      }

      const updatedScheme = {
        ...formState,
        rows: formState.rows.map((row, idx) => {
          if (rowIndex === idx) {
            return {
              ...row,
              minRangeDisplay: lowRangeAsString,
            }
          } else if (rowIndex === idx - 1) {
            return {
              ...row,
              maxRangeDisplay: lowRangeAsString,
            }
          } else {
            return row
          }
        }),
      }
      setFormState(updatedScheme)
    }

    const handleRowLowRangeChanged = (rowIndex: number, lowRangeDisplay: string) => {
      const updatedScheme = {
        ...formState,
        rows: formState.rows.map((row, idx) => {
          if (rowIndex === idx) {
            return {
              ...row,
              minRangeDisplay: lowRangeDisplay,
            }
          } else if (rowIndex === idx - 1) {
            return {
              ...row,
              maxRangeDisplay: lowRangeDisplay,
            }
          } else {
            return row
          }
        }),
      }
      setFormState(updatedScheme)
    }

    const handleBlurRowHighRange = (rowIndex: number, highRangeInputAsString: string) => {
      if (rowIndex !== 0) {
        throw Error('scaling factor may only be changed on the first row')
      }
      const updatedScheme = {
        ...formState,
      }
      const highRange = numberHelper._parseNumber(highRangeInputAsString)
      let highRangeAsString = highRangeInputAsString
      if (!Number.isNaN(highRange)) {
        updatedScheme.scalingFactor = roundToTwoDecimalPlaces(highRange)
        highRangeAsString = String(updatedScheme.scalingFactor)
      } else {
        updatedScheme.scalingFactor = NaN
      }
      updatedScheme.rows[rowIndex].maxRangeDisplay = highRangeAsString
      setFormState(updatedScheme)
    }

    const handleRowHighRangeChanged = (rowIndex: number, highRangeDisplay: string) => {
      if (rowIndex !== 0) {
        throw Error('scaling factor may only be changed on the first row')
      }
      const updatedScheme = {
        ...formState,
      }
      updatedScheme.rows[rowIndex].maxRangeDisplay = highRangeDisplay

      const inputVal = numberHelper.parse(highRangeDisplay)
      if (!Number.isNaN(Number(inputVal))) {
        updatedScheme.scalingFactor = roundToTwoDecimalPlaces(inputVal)
      } else {
        updatedScheme.scalingFactor = NaN
      }
      setFormState(updatedScheme)
    }

    const changeTitle = (e: ChangeEvent<HTMLInputElement>) => {
      const title = e.currentTarget.value.trim()
      const updatedScheme = {
        ...formState,
        title,
      }
      setFormState(updatedScheme)
    }
    const addDataRowAfterRow = (rowIndex: number) => {
      const [rowBefore, rowAfter] = formState.rows.slice(rowIndex, rowIndex + 2)

      const rowBeforeLowRangeAsPercentage = rangeDisplayStringToDecimal(
        rowBefore.minRangeDisplay,
        formState.scalingFactor
      )
      const rowAfterLowRangeAsPercentage = rowAfter
        ? rangeDisplayStringToDecimal(rowAfter.minRangeDisplay, formState.scalingFactor)
        : 0

      const lowRangeForNewRowAsPercentage =
        (rowBeforeLowRangeAsPercentage - rowAfterLowRangeAsPercentage) / 2 +
        rowAfterLowRangeAsPercentage
      const lowRangeForNewRowScaledForDisplay = rangeScaledForDisplay(
        lowRangeForNewRowAsPercentage,
        formState.scalingFactor
      )

      const updatedScheme = {
        ...formState,
      }

      updatedScheme.rows.splice(rowIndex + 1, 0, {
        uniqueId: shortid(),
        letterGrade: '',
        minRangeDisplay: lowRangeForNewRowScaledForDisplay,
        maxRangeDisplay: rowBefore.minRangeDisplay,
      })

      setFormState(updatedScheme)
    }

    const removeDataRow = (index: number) => {
      const updatedScheme = {
        ...formState,
      }
      updatedScheme.rows.splice(index, 1)
      if (updatedScheme.rows.length > 0) {
        // the last data row always has a min range of 0
        updatedScheme.rows[updatedScheme.rows.length - 1].minRangeDisplay = '0'
      }
      if (updatedScheme.rows.length === 1) {
        // only one row remains. by definition it must be 100% high range and 0% low range
        updatedScheme.rows[0].minRangeDisplay = '0'
      }
      setFormState(updatedScheme)
    }

    function rangeScaledForDisplay(range: number, displayScalingFactor: number): string {
      return String(roundToTwoDecimalPlaces(range * displayScalingFactor))
    }

    return (
      <View>
        {showAlert && formState ? (
          <GradingSchemeValidationAlert
            formData={{
              title: formState.title,
              data: formState.rows.map(row => ({
                name: row.letterGrade,
                value: rangeDisplayStringToDecimal(row.minRangeDisplay, formState.scalingFactor),
              })),
              scalingFactor: formState.scalingFactor,
              pointsBased: formState.pointsBased,
            }}
            onClose={() => setShowAlert(false)}
          />
        ) : (
          <></>
        )}

        <View as="div" withVisualDebug={false}>
          <View as="div" padding="none none small none" withVisualDebug={false}>
            <View as="div" padding="small none small none">
              <TextInput
                isRequired={true}
                width="23rem"
                renderLabel={I18n.t('Grading Scheme Name')}
                onChange={changeTitle}
                defaultValue={formState.title}
                placeholder={I18n.t('New Grading Scheme')}
              />
            </View>
            {pointsBasedGradingSchemesFeatureEnabled ? (
              <View as="div" padding="none none small none" withVisualDebug={false}>
                <RadioInputGroup
                  layout="columns"
                  name={`pointsBased_${shortid()}`}
                  defaultValue={formState.pointsBased ? 'points' : 'percentage'}
                  description={I18n.t('Grade by')}
                  onChange={(event: any, newValue: string) => handlePointsBasedChanged(newValue)}
                >
                  <RadioInput value="percentage" label={I18n.t('Percentage')} />
                  <RadioInput value="points" label={I18n.t('Points')} />
                </RadioInputGroup>
              </View>
            ) : (
              <></>
            )}
          </View>
          <table style={{width: '100%'}}>
            <caption>
              <ScreenReaderContent>
                {I18n.t(
                  'A table that contains the grading scheme data. Each row contains a name, a maximum percentage, and a minimum percentage. In addition, each row contains a button to add a new row below, and a button to delete the current row.'
                )}
              </ScreenReaderContent>
            </caption>
            <thead>
              <tr>
                <th style={{width: '5%'}}>
                  <ScreenReaderContent>{I18n.t('Add row action')}</ScreenReaderContent>
                </th>
                <th style={{width: '30%', textAlign: 'start'}}>{I18n.t('Letter Grade')}</th>
                <th colSpan={2} style={{width: '50%', textAlign: 'start'}}>
                  {I18n.t('Range')}
                </th>
                <th style={{width: '15%'}}>
                  <ScreenReaderContent>{I18n.t('Actions')}</ScreenReaderContent>
                </th>
              </tr>
            </thead>
            <tbody>
              {formState.rows.map((row, idx, array) => (
                <Fragment key={row.uniqueId}>
                  <GradingSchemeDataRowInput
                    letterGrade={row.letterGrade}
                    lowRangeDefaultDisplay={row.minRangeDisplay}
                    highRangeDefaultDisplay={row.maxRangeDisplay}
                    isFirstRow={idx === 0}
                    onLowRangeChange={lowRangeValue => handleRowLowRangeChanged(idx, lowRangeValue)}
                    onLowRangeBlur={lowRangeValue => handleBlurRowLowRange(idx, lowRangeValue)}
                    onRowLetterGradeChange={letterGrade => changeRowLetterGrade(idx, letterGrade)}
                    onRowDeleteRequested={() => removeDataRow(idx)}
                    onRowAddRequested={() => addDataRowAfterRow(idx)}
                    isLastRow={idx === array.length - 1}
                    pointsBased={formState.pointsBased}
                    displayScalingFactor={formState.scalingFactor}
                    onHighRangeChange={it => handleRowHighRangeChanged(idx, it)}
                    onHighRangeBlur={highRangeValue => handleBlurRowHighRange(idx, highRangeValue)}
                  />
                </Fragment>
              ))}
            </tbody>
          </table>
        </View>
      </View>
    )
  }
)
