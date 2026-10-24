# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1013 @LDTXMP4
Feature: LDTXMP4 preserve segment timing

  @LUB-1013.1 @Unit
  Scenario: Rescale audio timing without changing media payload
    Given an MP4 audio fragment with sample durations in its source timescale
    When its timestamps and durations are rewritten into a different timescale
    Then the mapped timestamps and sample durations use the destination timescale
    And the encoded media payload is unchanged
    And sample data offsets still locate the media payload

  @LUB-1013.2 @Integration
  Scenario: Finalize accepted media
    Given a segmented writer with accepted audio and video samples
    When the writer is finished
    Then accepted media is finalized before completion is reported

