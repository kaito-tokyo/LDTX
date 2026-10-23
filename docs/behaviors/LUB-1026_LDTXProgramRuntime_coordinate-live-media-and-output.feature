# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1026 @LDTXProgramRuntime
Feature: LDTXProgramRuntime coordinate live media and output

  @LUB-1026.1 @Integration
  Scenario: Deliver current input frames
    Given a runtime with a controllable video source
    When a new source frame is accepted
    Then consumers can retrieve the current frame without receiving invalidated frames

  @LUB-1026.2 @Integration
  Scenario: Use a session settings snapshot
    Given a runtime with saved output settings
    When output starts and editable settings subsequently change
    Then the active session retains its captured settings

  @LUB-1026.3 @Integration
  Scenario: Finish accepted work before stopping
    Given an output session with accepted media and screenshot package copies
    When stop is requested
    Then admission closes and accepted work finishes before the recording is finalized

  @LUB-1026.4 @Integration
  Scenario: Produce overlays independently
    Given a runtime with Clock or Dynamic Text overlays
    When overlay content changes while no Program frame is requested
    Then overlay generation can publish a new texture without invoking composition

