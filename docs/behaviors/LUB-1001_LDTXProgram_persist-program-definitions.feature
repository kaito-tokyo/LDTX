# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1001 @LDTXProgram
Feature: LDTXProgram persist program definitions

  @LUB-1001.1 @Unit
  Scenario: Round trip component definitions
    Given a Program containing configured video components
    When the Program is serialized and decoded
    Then component identities, settings, and canvas assignments are preserved

  @LUB-1001.2 @Unit
  Scenario: Preserve independent canvas preferences
    Given different Landscape and Portrait layer preferences
    When one canvas preference is changed
    Then the other canvas retains its settings

