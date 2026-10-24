# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1065 @LDTXWorkspaceAppletService
Feature: manage program library order

  @LUB-1065.1 @Unit
  Scenario: Create both silent canvas mixes
    Given an empty Program library
    When a new Program is appended
    Then both required canvas mixes exist with silent audio

  @LUB-1065.2 @Unit
  Scenario: Reorder Programs within library bounds
    Given an ordered Program library with a current selection
    When a Program is moved within or beyond the list bounds
    Then valid moves change only order and invalid moves do not persist an invalid list
