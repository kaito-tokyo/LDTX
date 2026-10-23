# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1042 @LDTXVisionProgrammerApp
Feature: LDTXVisionProgrammerApp open standalone training

  @LUB-1042.1 @UI
  Scenario: Open the training interface
    Given the standalone Vision Programmer application
    When the application launches
    Then the training interface is available

