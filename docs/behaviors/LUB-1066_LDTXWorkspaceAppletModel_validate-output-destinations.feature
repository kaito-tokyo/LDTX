# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1066 @LDTXWorkspaceAppletModel
Feature: validate output destinations

  @LUB-1066.1 @Unit
  Scenario: Preserve explicit destination choices until Start
    Given output settings with disabled destinations or a disconnected folder
    When settings are normalized
    Then the user's choice remains intact for Start-time validation rather than silently choosing another destination

  @LUB-1066.2 @Unit
  Scenario: Commit folder overrides atomically
    Given a request to enable or disable a recording folder override
    When the folder choice is committed or cancelled
    Then enabling requires a selected normalized folder and disabling clears the override

  @LUB-1066.3 @Integration
  Scenario: Check a local output directory without changing it
    Given an existing or missing recording destination
    When writability is probed
    Then usable directories remain unchanged and missing directories report unavailable

  @LUB-1066.4 @Unit
  Scenario: Reject unsupported encoding profiles
    Given a dual-canvas output configuration
    When the profile and bit rates are validated
    Then supported positive bit rates are accepted and unsupported profiles or nonpositive rates are rejected

  @LUB-1066.5 @UIComponent
  Scenario Outline: Present output toolbar controls for the current state
    Given output state <state>
    When the owning window validates its toolbar
    Then Stop is enabled <stopEnabled> and Start or Pause is enabled <toggleEnabled>
    And the toggle title is "<title>"

    Examples:
      | state     | stopEnabled | toggleEnabled | title        |
      | idle      | false       | true          | Start Output |
      | starting  | true        | false         | Start Output |
      | recording | true        | true          | Pause Output |
      | pausing   | false       | false         | Start Output |
      | paused    | true        | true          | Start Output |
      | stopping  | false       | false         | Start Output |
      | failed    | false       | true          | Start Output |

  @LUB-1066.6 @UIComponent
  Scenario Outline: Dispatch toolbar output actions only to their owning runtime
    Given two windows and output state <state> in the first window
    When its toolbar item <item> is invoked
    Then its runtime receives <actions> and the other runtime receives no action

    Examples:
      | state     | item                       | actions |
      | idle      | workspace.startPauseOutput | start   |
      | recording | workspace.startPauseOutput | pause   |
      | paused    | workspace.stopOutput       | stop    |
      | pausing   | workspace.startPauseOutput | none    |
