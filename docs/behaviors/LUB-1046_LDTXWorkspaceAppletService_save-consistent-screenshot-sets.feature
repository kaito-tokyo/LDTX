# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1046 @LDTXWorkspaceAppletService
Feature: LDTXWorkspaceAppletService save consistent screenshot sets

  @LUB-1046.1 @Integration
  Scenario: Roll back a partially written capture set
    Given a screenshot destined for global storage and an active recording package
    When one required write fails after another has succeeded
    Then the capture reports failure and the files already written for that capture are removed

  @LUB-1046.2 @Integration
  Scenario: Bound pending screenshot work
    Given a Workspace with one screenshot being saved and one waiting
    When another screenshot is requested
    Then the new request reports busy without adding more pending work

  @LUB-1046.3 @Integration
  Scenario: Drain package copies before recording finalization
    Given a recording with an accepted screenshot package copy whose write is suspended
    When Stop or Pause is requested
    Then new package copies are rejected and finalization waits for the accepted copy

  @LUB-1046.4 @UIComponent
  Scenario Outline: Keep screenshot actions available independently of output mode
    Given a window with output active <outputActive> and local recording <localRecording>
    When its screenshot toolbar action is invoked
    Then the action is enabled and requests one capture from its own runtime

    Examples:
      | outputActive | localRecording |
      | false        | false          |
      | true         | false          |
      | true         | true           |
