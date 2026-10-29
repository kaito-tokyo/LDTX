# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1073 @LDTXApp
Feature: Notify about saved screenshots

  @LUB-1073.1 @UIComponent
  Scenario: Prepare a notification without moving saved screenshots
    Given a saved set containing Landscape and Portrait Program screenshots
    When notification content is prepared
    Then the Landscape image is attached from a copy and the capture time is displayed
    And the original files remain available as the notification's Finder targets
