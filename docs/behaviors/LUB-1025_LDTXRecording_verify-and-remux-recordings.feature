# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1025 @LDTXRecording
Feature: LDTXRecording verify and remux recordings

  @LUB-1025.1 @Integration
  Scenario: Verify package media
    Given a recording package with referenced audio and video tracks
    When the package is verified
    Then missing or invalid media is reported

  @LUB-1025.2 @Integration
  Scenario: Remux a valid recording
    Given a valid segmented recording with known media timing
    When the recording is remuxed
    Then the output preserves the recorded audio and video timeline

