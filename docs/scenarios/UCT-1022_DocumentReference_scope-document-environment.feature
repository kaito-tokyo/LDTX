# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1022 @DocumentReference
Feature: Scope document environment

  @UCT-1022.1
  Scenario: Nested views follow their own document URL
    Given nested hosted views are connected to different Documents
    When one Document changes its URL
    Then each view reads the current URL of its own Document

  @UCT-1022.2
  Scenario: Hosted views do not retain the Document
    Given a hosted view retains its Document reference
    When the owning Document reference is released
    Then the Document is deallocated

  @UCT-1022.3
  Scenario: A missing Document environment is safe
    Given a hosted view has no Document reference
    When the view reads its Document environment
    Then the view receives no Document and remains usable
