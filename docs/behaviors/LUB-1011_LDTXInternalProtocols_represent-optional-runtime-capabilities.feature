# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1011 @LDTXInternalProtocols
Feature: LDTXInternalProtocols represent optional runtime capabilities

  @LUB-1011.1 @Unit
  Scenario: Represent missing Vision results
    Given a Vision presentation provider with no result for an ID
    When the status and result are queried
    Then the provider can report unavailable without inventing a recognition result

  @LUB-1011.2 @Integration
  Scenario: Distinguish mask availability states
    Given an optional background-removal provider
    When the consumer receives ready, preparing, or unavailable
    Then only ready provides an alpha texture

