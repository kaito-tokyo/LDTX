# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1023 @ItemNameDialog
Feature: Name input validation

  @UCT-1023.1
  Scenario: Whitespace is removed from a valid candidate
    Given a name dialog whose available candidate is surrounded by whitespace
    When the dialog evaluates the candidate
    Then the candidate has no surrounding whitespace
    And submission is enabled

  @UCT-1023.2
  Scenario: An empty candidate cannot be submitted
    Given a name dialog whose candidate contains only whitespace
    When the dialog evaluates the candidate
    Then the candidate is empty
    And submission is disabled

  @UCT-1023.3
  Scenario: An existing name cannot be submitted
    Given a name dialog whose candidate matches an existing name after trimming
    When the dialog evaluates the candidate
    Then submission is disabled
