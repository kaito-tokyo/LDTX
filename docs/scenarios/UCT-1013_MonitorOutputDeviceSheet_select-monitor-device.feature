# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1013 @MonitorOutputDeviceSheet
Feature: Select a monitor output device

  @UCT-1013.1
  Scenario: Selection starts empty and unavailable drafts clear before applying
    Given a monitor output assignment exists and output candidates are available
    When the sheet opens and a selected draft candidate disappears before another is applied
    Then the current assignment is displayed separately from an initially empty selection
    And removal clears the draft without changing the saved assignment
    And only applying an explicit selection updates the assignment and closes the sheet
