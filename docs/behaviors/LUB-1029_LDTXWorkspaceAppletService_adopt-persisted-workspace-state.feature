# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1029 @LDTXWorkspaceAppletService
Feature: LDTXWorkspaceAppletService adopt persisted workspace state

  @LUB-1029.1 @Integration
  Scenario: Adopt only successfully persisted definitions
    Given runtime definition A and editable definition B
    When a save of B fails
    Then the runtime continues using A and editable content remains B
    And a subsequent successful save adopts B

  @LUB-1029.2 @Unit
  Scenario: Schedule Vision without catch-up queues
    Given Vision occurrences whose execution lane is busy or overdue
    When their scheduled time arrives
    Then those occurrences are skipped instead of accumulating catch-up work
    And initial phases are distributed within fixed-budget frames without overlapping reservations
    And long or fractional periods retain their timing across frame boundaries

  @LUB-1029.3 @Integration
  Scenario: Preserve output failures through cleanup
    Given an output session with a startup or finalization failure
    When cleanup completes
    Then the actionable failure remains available for presentation

  @LUB-1029.4 @Unit
  Scenario: Encode resource names as single path components
    Given resource names containing dots, slashes, percent signs, or null characters
    When each name is encoded for a resource path
    Then those characters are escaped within a single path component
    And distinct names do not collide through escaping

  @LUB-1029.5 @Unit
  Scenario: Preserve canvas visibility in the runtime graph
    Given a saved Program whose camera layer is hidden on one canvas
    When its runtime graph is built
    Then that canvas marks the camera layer hidden for rendering
    And visibility on the other canvas is unchanged

  @LUB-1029.6 @Integration
  Scenario: Capture output settings at session start
    Given saved output settings A
    When output starts and editable output settings become B
    Then the active session continues using A
    And the next session uses B only after B has been successfully saved

