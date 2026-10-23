# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1026 @LDTXProgramRuntime
Feature: LDTXProgramRuntime coordinate live media and output

  @LUB-1026.1 @Integration
  Scenario: Invalidate failed capture frames
    Given a camera with a previously accepted frame
    When capture reports a runtime failure
    Then the failed camera's frame becomes unavailable until a new frame is accepted

  @LUB-1026.2 @Unit
  Scenario: Maintain cadence without source timestamps
    Given a 30 fps video timeline with frame 10 timestamped at zero
    When the next accepted frame is frame 14 without a source timestamp
    Then its timestamp is 4 divided by 30 seconds
    And switching pipelines does not reuse the previous pipeline's frame numbering

  @LUB-1026.3 @Integration
  Scenario: Stop only after media delivery finishes
    Given an output session with accepted media and an in-flight delivery callback
    When stop is requested
    Then new media is rejected and stop completes after accepted delivery and finalization

  @LUB-1026.4 @Integration
  Scenario: Produce overlays independently
    Given a runtime with Clock or Dynamic Text overlays
    When overlay content changes while no Program frame is requested
    Then overlay generation publishes a new texture without invoking composition
