# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1033 @LDTXAppletSupport
Feature: LDTXAppletSupport coordinate application termination

  @LUB-1033.1 @Unit
  Scenario: Cancel termination without stopping participants
    Given participants including one that refuses confirmation
    When application termination is requested
    Then confirmation is cancelled and no participant is stopped

  @LUB-1033.2 @Unit
  Scenario: Wait for confirmed participants
    Given participants that all confirm termination
    When application termination is requested
    Then all participant stop operations finish before termination succeeds

