# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
# SPDX-License-Identifier: Apache-2.0

@UCT-1025 @OcrVisionInspector
Feature: Invalid ROI prevents leaving
  Invalid input stays visible in its editing screen until corrected.

  @UCT-1025.1 @WorkspaceStoreService
  Scenario: Invalid drafts block navigation without corrupting the model
    Given an OCR Inspector has a valid saved ROI
    When invalid or unparseable coordinates are entered
    And the user attempts to select another Inspector
    Then an error is reported and selection remains on the OCR Inspector
    And the text draft is preserved and the saved model is unchanged
    And validation prevents saving or leaving with pending invalid edits

  @UCT-1025.2 @WorkspaceStoreService
  Scenario: Correcting the complete rectangle allows navigation
    Given an ROI draft extends beyond the image
    When the remaining fields are corrected so the whole rectangle fits
    Then the valid rectangle is committed
    And the user can leave the Inspector
