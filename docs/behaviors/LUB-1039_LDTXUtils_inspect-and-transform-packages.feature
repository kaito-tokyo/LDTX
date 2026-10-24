# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1039 @LDTXUtils
Feature: LDTXUtils inspect and transform packages

  @LUB-1039.1 @Integration
  Scenario: Read a supplied recording package
    Given a valid recording package and a CLI read command
    When the command executes
    Then the reported recording information matches the package

  @LUB-1039.2 @Integration
  Scenario: Fail on invalid input
    Given a CLI package command with missing or invalid input
    When the command executes
    Then it reports failure instead of a successful empty result

