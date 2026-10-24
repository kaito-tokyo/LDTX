# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1045 @LDTXWorkspaceAppletService
Feature: LDTXWorkspaceAppletService run current manual ocr

  @LUB-1045.1 @Integration
  Scenario: Report backend failure and permit retry
    Given a saved OCR Vision and an available input frame
    When recognition fails and a later manual request succeeds
    Then the first request reports its original error without publishing or archiving a result
    And the later request publishes its recognized text

  @LUB-1045.2 @Integration
  Scenario: Discard results from an obsolete saved definition
    Given a manual OCR request using a saved Workspace generation
    When another successful save replaces that generation before recognition completes
    Then the old request cannot update the new generation's variables or archive

  @LUB-1045.3 @Integration
  Scenario: Archive only into the originating active recording
    Given a manual OCR request accepted during recording A
    When recording A stops and recording B starts before recognition completes
    Then the result is not archived into recording B
