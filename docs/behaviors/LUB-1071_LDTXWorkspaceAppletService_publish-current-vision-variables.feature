# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1071 @LDTXWorkspaceAppletService
Feature: Publish current Vision variables

  @LUB-1071.1 @Unit
  Scenario: Derive OCR configuration from saved values
    Given a saved OCR definition with languages, correction, custom words, and minimum text height
    When its recognition configuration is created
    Then explicit settings are preserved and absent minimum text height uses the protobuf default

  @LUB-1071.2 @Integration
  Scenario: Replace variable inventory only on persisted adoption
    Given a Workspace with current Vision variables and an in-flight result
    When a new saved definition is adopted
    Then its variable inventory and defaults replace the previous store
    And results from the old generation cannot update the replacement

  @LUB-1071.3 @Integration
  Scenario: Publish recognized values atomically
    Given valid OCR or classification results and their declared variable keys
    When results are published manually or automatically
    Then the corresponding values update together and invalid keys do not partially mutate the store
    And classification reports the highest-confidence candidate with stable tie order

