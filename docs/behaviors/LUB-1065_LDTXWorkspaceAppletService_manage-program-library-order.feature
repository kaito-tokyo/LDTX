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
  Scenario Outline: Reject Program moves beyond library boundaries
    Given library order One, Two
    When Program <program> moves by <offset>
    Then the move is rejected and library order remains One, Two

    Examples:
      | program | offset |
      | One     | -1     |
      | Two     | 1      |

  @LUB-1065.3 @Unit
  Scenario: Persist a valid Program move
    Given a library with multiple Programs
    When a Program moves to another valid position
    Then the new order is persisted without changing Program content
