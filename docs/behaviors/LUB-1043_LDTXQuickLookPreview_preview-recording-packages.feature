# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1043 @LDTXQuickLookPreview
Feature: LDTXQuickLookPreview preview recording packages

  @LUB-1043.1 @Integration
  Scenario: Preview a valid recording
    Given a valid recording package
    When Quick Look requests a preview
    Then the provider returns a preview for the recording

  @LUB-1043.2 @Integration
  Scenario: Report an invalid recording package
    Given a package whose main media URL cannot be resolved
    When Quick Look requests a preview
    Then the provider reports failure instead of a valid media preview

