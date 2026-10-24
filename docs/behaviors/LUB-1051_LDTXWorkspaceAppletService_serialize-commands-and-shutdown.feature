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
