# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1014 @LDTXDash
Feature: LDTXDash publish consistent segments

  @LUB-1014.1 @Unit
  Scenario: Reference available segments
    Given a stream with committed media segments
    When a DASH manifest is generated
    Then the manifest describes the committed segment timeline

  @LUB-1014.2 @Integration
  Scenario: Expose upload failure
    Given a media upload transport that fails
    When a segment is uploaded
    Then the failure remains observable to the pipeline caller

  @LUB-1014.3 @Integration
  Scenario: Drain before finalizing
    Given an upload pipeline with accepted pending segments
    When finish is requested
    Then accepted uploads complete before finalization succeeds

