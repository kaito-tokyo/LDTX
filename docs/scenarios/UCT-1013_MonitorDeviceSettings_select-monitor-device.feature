# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1013 @MonitorDeviceSettings
Feature: Select a monitor output device

  @UCT-1013.1
  Scenario: Disappearing candidates do not change assignment
    Given a monitor output assignment exists and output candidates are available
    When a candidate disappears before selection is confirmed internally
    Then availability is rechecked without changing the saved assignment
    And the unavailable current assignment remains visible

  @UCT-1013.2 @SettingsApplet @WorkspaceDocument
  Scenario: Selection immediately persists globally
    Given Settings Audio offers a physical device and System Default
    When a device is selected
    Then the application-wide assignment is immediately saved and survives reopening
    And selecting System Default immediately changes the assignment
    And the Workspace Document remains unedited
    And both active audio engines reconfigure using the application-wide assignment

  @UCT-1013.3 @SettingsApplet
  Scenario: Discovery failures preserve assignment and report once until recovery
    Given a saved output assignment
    When device discovery repeatedly fails
    Then the assignment is preserved and no device change is committed
    And the error is reported once until discovery recovers
    And a failure after recovery is reported again
