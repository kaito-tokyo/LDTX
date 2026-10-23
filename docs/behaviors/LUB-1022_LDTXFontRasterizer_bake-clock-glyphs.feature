# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1022 @LDTXFontRasterizer
Feature: LDTXFontRasterizer bake clock glyphs

  @LUB-1022.1 @Unit
  Scenario: Produce usable Clock glyph metrics
    Given the bundled Clock font and a sufficiently sized atlas
    When Clock ASCII glyphs are baked
    Then the result contains glyph metrics and atlas coordinates for the supported characters

  @LUB-1022.2 @Unit
  Scenario: Report insufficient atlas capacity
    Given an atlas too small for the requested glyph table
    When Clock ASCII glyphs are baked
    Then the function returns failure instead of a usable glyph count

