# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1006 @LDTXTaskQueue
Feature: LDTXTaskQueue sequence and finish work

  @LUB-1006.1 @Integration
  Scenario: Preserve FIFO order across suspension
    Given a resource queue whose first command is suspended and whose second command is pending
    When the first command is released
    Then the first command completes before the second executes

  @LUB-1006.2 @Integration
  Scenario: Drain accepted commands on finish
    Given a resource queue with accepted commands
    When finish is requested
    Then new commands are rejected and finish completes after the accepted commands

  @LUB-1006.3 @Integration
  Scenario: Discard pending commands on stop
    Given a resource queue with a suspended running command and pending commands
    When stop is requested and the running command observes cancellation
    Then pending commands never execute and stop completes after the running command exits

  @LUB-1006.4 @Unit
  Scenario: Deduplicate background task keys
    Given a background task key that is running or pending
    When another task with that key is submitted
    Then the duplicate is rejected without running its task

  @LUB-1006.5 @Unit
  Scenario: Ignore repeated background completion
    Given a background task whose completion has already advanced the queue
    When that completion is called again
    Then the next running task is not completed or skipped
