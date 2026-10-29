# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1051 @LDTXWorkspaceAppletService
Feature: serialize commands and shutdown

  @LUB-1051.1 @Integration
  Scenario: Drain accepted commands before closing
    Given a Workspace with an accepted suspended resource operation
    When close is requested
    Then close waits for that operation without blocking unrelated Workspaces and releases resources once

  @LUB-1051.2 @Integration
  Scenario: Require an explicit retry after a stalled operation
    Given a failed command that leaves the resource queue stalled
    When the error is acknowledged or unrelated state changes
    Then the failed command is not automatically replayed and only a new valid user request retries it

  @LUB-1051.3 @Integration
  Scenario: Retain failures through asynchronous shutdown
    Given a Workspace whose cleanup or capture fails while closing
    When shutdown completes or Quit is cancelled
    Then the originating owner presents the actionable failure without reporting a successful close

  @LUB-1051.4 @Integration
  Scenario: Keep queue ordering through cancellation
    Given queued resource commands with a running operation
    When stop or a cancellation barrier is requested
    Then accepted operations observe their prescribed completion order and stale callbacks cannot reopen closed admission

  @LUB-1051.5 @UIComponent
  Scenario: Present Workspace errors in order
    Given a Workspace with multiple reported operation errors
    When the user acknowledges each alert
    Then the errors are presented in order with their details

  @LUB-1051.6 @UIComponent
  Scenario: Report recurring runtime failures after recovery
    Given two Workspace windows with independent runtime failures
    When a failure repeats, recovers, and recurs
    Then only its owning Workspace presents the continuing failure once
    And the recurrence is reported again

  @LUB-1051.7 @UIComponent
  Scenario: Stop reporting Workspace errors after shutdown
    Given a Workspace coordinator with queued operation errors
    When the coordinator shuts down and another error is reported
    Then the queued errors are cleared and the late error is not presented

  @LUB-1051.8 @UIComponent
  Scenario: Finish a queued save before closing the Workspace
    Given a Workspace save is writing while a later save is requested
    When the user closes the Workspace before both saves finish
    Then closing waits for the queued save
    And the package contains the later save's captured content
