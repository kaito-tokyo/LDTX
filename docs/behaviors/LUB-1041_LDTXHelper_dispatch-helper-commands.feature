# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1041 @LDTXHelper
Feature: LDTXHelper dispatch helper commands

  @LUB-1041.1 @Integration
  Scenario: Serve automation over standard input and output
    Given the helper running in automation mode
    When a supported JSON-RPC request is written to standard input
    Then a corresponding JSON-RPC response is written to standard output

