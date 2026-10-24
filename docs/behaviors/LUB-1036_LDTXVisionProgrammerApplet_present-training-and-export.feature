# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1036 @LDTXVisionProgrammerApplet
Feature: LDTXVisionProgrammerApplet present training and export

  @LUB-1036.1 @UIComponent
  Scenario: Export after successful training
    Given a training view using a controllable training service
    When training succeeds
    Then the progress sheet closes and model export is presented

  @LUB-1036.2 @UIComponent
  Scenario: Present training failure
    Given a training view using a failing training service
    When training fails
    Then the failure is visible and no successful model export is offered

