# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1015 @WorkspaceWindowController
Feature: Present operation errors

  @UCT-1015.1
  Scenario: Errors are queued on the editing sheet and stop after shutdown
    Given a Workspace has an open editing sheet
    When multiple operation errors are reported and the Workspace shuts down
    Then error sheets preserve the explanation and recovery advice and are presented in order before shutdown

  @UCT-1015.2
  Scenario: Runtime failures are scoped and can recur after recovery
    Given two Workspace windows are open
    When one Workspace reports repeated monitor and capture failures followed by recovery and recurrence
    Then only that Workspace presents each continuing failure once and presents recurrence again

  @UCT-1015.3
  Scenario: Closing a window discards queued and late errors
    Given a Workspace window has a presented error and a queued error
    When the window closes and more operation failures arrive
    Then no further error sheet is presented
