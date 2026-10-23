# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1020 @LDTXProgramRendering
Feature: LDTXProgramRendering translate visible program layers

  @LUB-1020.1 @Integration
  Scenario: Respect saved layer order
    Given a Program with multiple visible layers
    When its composition is prepared
    Then drawing order matches the saved layer order

  @LUB-1020.2 @Integration
  Scenario: Exclude hidden layers
    Given a Program containing a hidden video layer
    When its composition is prepared
    Then the hidden layer contributes no drawing command or dummy replacement

