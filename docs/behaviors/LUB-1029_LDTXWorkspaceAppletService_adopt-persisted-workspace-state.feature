# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1029 @LDTXWorkspaceAppletService
Feature: LDTXWorkspaceAppletService adopt persisted workspace state

  @LUB-1029.1 @Integration
  Scenario: Adopt only successfully persisted definitions
    Given editable content that differs from the runtime definition
    When saving succeeds or fails
    Then only a successful save replaces the runtime definition

  @LUB-1029.2 @Unit
  Scenario: Schedule Vision without catch-up queues
    Given Vision occurrences whose execution lane is busy or overdue
    When their scheduled time arrives
    Then those occurrences are skipped instead of accumulating catch-up work

  @LUB-1029.3 @Integration
  Scenario: Preserve output failures through cleanup
    Given an output session with a startup or finalization failure
    When cleanup completes
    Then the actionable failure remains available for presentation

  @LUB-1029.4 @Integration
  Scenario: Reject resource path escapes
    Given a resource destination with unsafe path components
    When the resource path is resolved
    Then the destination cannot escape the intended resource directory

