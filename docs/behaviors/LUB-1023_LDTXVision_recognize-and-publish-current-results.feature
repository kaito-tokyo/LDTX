# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1023 @LDTXVision
Feature: LDTXVision recognize and publish current results

  @LUB-1023.1 @Integration
  Scenario: Recognize a supported text fixture
    Given a known text image on a supported Vision backend
    When OCR runs using the configured region
    Then the expected text is recognized

  @LUB-1023.2 @Integration
  Scenario: Keep failure retryable
    Given a manual OCR request whose backend fails
    When the caller retries after the failure
    Then the original failure is reported and the later request can succeed

  @LUB-1023.3 @Integration
  Scenario: Reject obsolete result publication
    Given an in-flight request for an earlier runtime generation
    When the generation is replaced before recognition finishes
    Then the obsolete result does not update current variables or archives

