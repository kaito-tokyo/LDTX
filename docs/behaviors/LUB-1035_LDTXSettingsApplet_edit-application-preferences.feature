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

  @LUB-1035.3 @UIComponent
  Scenario: Persist monitor selection independently of Workspace edits
    Given Settings offers a physical output device and System Default
    When the monitor selection changes
    Then the application-wide selection is saved and active audio engines update
    And the Workspace document is not marked edited

  @LUB-1035.4 @UIComponent
  Scenario: Report monitor discovery failures until recovery
    Given a saved monitor assignment
    When discovery repeatedly fails and later recovers
    Then the assignment remains unchanged and the continuing failure is reported once
    And a new failure after recovery is reported again

