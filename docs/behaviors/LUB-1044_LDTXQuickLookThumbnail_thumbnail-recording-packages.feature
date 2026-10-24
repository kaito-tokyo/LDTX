# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1044 @LDTXQuickLookThumbnail
Feature: LDTXQuickLookThumbnail thumbnail recording packages

  @LUB-1044.1 @Integration
  Scenario: Create a recording thumbnail
    Given a recording package with usable video
    When Quick Look requests a thumbnail
    Then the provider returns an image within the requested thumbnail bounds

  @LUB-1044.2 @Integration
  Scenario: Handle unavailable video
    Given a package without usable video
    When Quick Look requests a thumbnail
    Then the provider completes with an error and no thumbnail reply

