# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1061 @LDTXMP4
Feature: encode decodable timed media

  @LUB-1061.1 @Integration
  Scenario: Encode supported H264 without frame reordering
    Given valid full-range NV12 frames with known presentation timestamps
    When the encoder emits and finishes H264 samples
    Then samples preserve presentation time, use the supported profile, and honor requested and periodic keyframes

  @LUB-1061.2 @Integration
  Scenario: Validate codec and sample envelopes
    Given unsupported H264 configuration or invalid passthrough sample timing
    When encoding or append is attempted
    Then the input is rejected before it can corrupt the output timeline

  @LUB-1061.3 @Integration
  Scenario: Account for AAC priming and trim
    Given PCM with a known sample rate, start, and frame count
    When AAC encoding completes
    Then codec configuration and trim metadata describe exactly the accepted source frames

  @LUB-1061.4 @Integration
  Scenario: Reject discontinuous AAC input
    Given successive PCM samples with a gap, overlap, or accumulated drift beyond rounding tolerance
    When they are encoded
    Then the discontinuity is reported while supported small rounding differences remain accepted

  @LUB-1061.5 @Integration
  Scenario: Preserve PCM timing and silence intervals
    Given PCM input with source-clock drift, missing intervals, or a sample-rate change
    When the audio writer finishes
    Then the resulting track preserves the input timeline and duration without fabricating media from an empty recording

  @LUB-1061.6 @Integration
  Scenario: Serialize writer start against pending finish
    Given a writer lifecycle finish held in progress
    When another writer start is requested
    Then start enters only after finish completes
