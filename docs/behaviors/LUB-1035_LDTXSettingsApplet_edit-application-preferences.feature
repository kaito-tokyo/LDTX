# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1035 @LDTXSettingsApplet
Feature: LDTXSettingsApplet edit application preferences

  @LUB-1035.1 @UIComponent
  Scenario: Keep unavailable monitor assignments
    Given a stored monitor assignment absent from current discovery
    When monitor settings are opened
    Then the saved assignment is not silently replaced by another device

  @LUB-1035.2 @UIComponent
  Scenario: Reflect account authorization state
    Given settings connected to a controllable authorization state
    When the account becomes authorized or signed out
    Then the account controls reflect the current authorization state

