# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1006 @LDTXTaskQueue
Feature: LDTXTaskQueue sequence and finish work

  @LUB-1006.1 @Unit
  Scenario: Order accepted work
    Given a queue with a running task and pending tasks
    When the running task completes
    Then accepted tasks execute in the queue's declared order

  @LUB-1006.2 @Unit
  Scenario: Close task admission during finish
    Given a queue with accepted work
    When finish is requested and another task is submitted
    Then new work is rejected and finalization follows the accepted work

  @LUB-1006.3 @Unit
  Scenario: Cancel without duplicate completion
    Given running and pending cancellable tasks
    When the queue is stopped
    Then pending work is dropped and each accepted completion is delivered at most once

