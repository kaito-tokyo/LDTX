# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1012 @LDTXMediaTiming
Feature: LDTXMediaTiming maintain audio timelines

  @LUB-1012.1 @Unit
  Scenario: Advance timestamps by sample count
    Given a 48000 Hz clock anchored at 2 seconds
    When batches of 480 and 960 frames arrive with later inconsistent anchors
    Then their presentation timestamps are 2 seconds and 2.01 seconds
    And the next batch starts at 2.03 seconds regardless of later anchors

  @LUB-1012.2 @Unit
  Scenario: Read audio at its presentation time and fill gaps with silence
    Given samples stored for frames 3 and 4 of a channel timeline
    When frames 1 through 5 are read
    Then frames 3 and 4 contain the stored samples
    And frames 1, 2, and 5 contain silence

