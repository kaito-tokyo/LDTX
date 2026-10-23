# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1013 @LDTXMP4
Feature: LDTXMP4 preserve segment timing

  @LUB-1013.1 @Unit
  Scenario: Preserve media timing boxes
    Given MP4 timing boxes with a declared timescale
    When the boxes are read and rewritten
    Then sample timing retains its value in that timescale

  @LUB-1013.2 @Integration
  Scenario: Finalize accepted media
    Given a segmented writer with accepted audio and video samples
    When the writer is finished
    Then accepted media is finalized before completion is reported

