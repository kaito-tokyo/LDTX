# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1059 @LDTXProgramRuntime
Feature: pace and normalize output time

  @LUB-1059.1 @Unit
  Scenario: Preserve cadence without catch-up bursts
    Given a paced output whose render time or frame rate changes
    When the next render delay is requested
    Then render time is subtracted from the interval and missed deadlines do not create a burst

  @LUB-1059.2 @Unit
  Scenario Outline: Advance only with valid master timestamps
    Given a selected video timing master with an accepted timestamp
    When a subsequent timestamp is <timestamp>
    Then output <result>

    Examples:
      | timestamp | result            |
      | later     | advances          |
      | missing   | does not advance  |
      | repeated  | does not advance  |
      | backward  | does not advance  |

  @LUB-1059.3 @Unit
  Scenario: Use host time without a configured master
    Given a Workspace without a selected video timing master
    When a video timestamp is selected
    Then the host clock supplies a numeric presentation time while audio inputs cannot become video masters

  @LUB-1059.4 @Unit
  Scenario: Apply a common recording origin
    Given audio and video samples with different start times
    When the recording timeline normalizes them
    Then relative track offsets remain intact and finalization uses the latest accepted media end

  @LUB-1059.5 @Unit
  Scenario: Bound pre-start and pending media by one time window
    Given samples arriving before output activation or out of order
    When the pending recording window advances
    Then only the bounded shared window is retained and late samples cannot move it backward

  @LUB-1059.6 @Unit
  Scenario: Require reset after changing timing masters
    Given a selector with an established video timing master
    When a different master is supplied without resetting the selector
    Then the new master cannot advance the old timing epoch
