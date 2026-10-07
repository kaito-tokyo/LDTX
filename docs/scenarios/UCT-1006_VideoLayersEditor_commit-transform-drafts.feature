# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1006 @VideoLayersEditor
Feature: Commit transform drafts

  @UCT-1006.1
  Scenario: Validation errors are reported and drafts survive
    Given two layer rows contain invalid position and scale drafts
    When each draft is submitted and then corrected
    Then errors identify the invalid fields and drafts remain available for correction

  @UCT-1006.2
  Scenario: Editor and table release wired rows
    Given a wired Editor, Table, and Row whose row state remains referenced
    When their owning UI references are released
    Then the Editor, Table, and Row are deallocated and retained callbacks remain safe

  @UCT-1006.3
  Scenario: Missing save delegate retains draft and hide
    Given a row has an unconfirmed transform but no save delegate
    When its transform and visibility callbacks are invoked
    Then the draft remains unconfirmed and visibility does not change

  @UCT-1006.4
  Scenario: Reflects preferences without overwriting editing text
    Given a reused layer row has an active text draft
    When external transform and visibility preferences change
    Then visibility updates while the active text draft is preserved

  @UCT-1006.5
  Scenario: Commits normalized numbers on submit
    Given a layer row contains pixel positions and scale drafts
    When the user submits those values
    Then integer positions persist with unreduced denominators of 1920 for X and 1080 for Y
    And decimal scales persist with a power-of-ten denominator

  @UCT-1006.6
  Scenario: Positions require integer pixels while scales preserve decimals
    Given a row contains decimal, fractional, or out-of-range pixel positions
    When the user submits the draft
    Then no transform is committed and the draft remains available
    When the user submits a fractional or unrepresentable scale
    Then no transform is committed and the draft remains available
    When the user submits valid integer positions and a decimal scale
    Then integer positions and the exact decimal scale are committed and restored

  @UCT-1006.7
  Scenario: App kit commit requests read current draft once
    Given a row contains a changed draft
    When commit is requested repeatedly and later requested after row removal
    Then the draft commits once and detached rows cannot commit again

  @UCT-1006.8
  Scenario: Hosted callbacks do not retain row
    Given hosted content retains callback state from a row
    When the row owner is released
    Then the row is deallocated and callbacks remain safe

  @UCT-1006.9
  Scenario: Invalid input survives model updates
    Given a scale draft is incomplete, unsupported, infinite, or too large
    When the user submits it and the layer list refreshes
    Then the draft remains intact and an error is reported without committing

  @UCT-1006.10
  Scenario: Failure retains draft and can be retried
    Given a transform draft has a failing persistence callback
    When submission fails and then succeeds on retry
    Then failure preserves the draft and retry commits and normalizes it

  @UCT-1006.11
  Scenario: Hosting view renders editable fields
    Given a layer row is hosted in an external table container
    When its fields are laid out and the layer order refreshes
    Then four editable fields remain usable and the same row is reused

  @UCT-1006.12
  Scenario: Hosted fields commit only on enter
    Given a hosted layer field has an unconfirmed edit
    When focus changes before Enter is pressed and the row is later removed
    Then only Enter commits and focus changes or detached callbacks do not commit

  @UCT-1006.13
  Scenario: Active editor survives ordinary refresh
    Given an active row contains an unconfirmed text value
    When the editor refreshes and another editor is created
    Then the active draft and row survive refresh without sharing row instances across editors

  @UCT-1006.14
  Scenario: Preference commit uses latest value and preserves insets
    Given a transform row is open while unrelated live preferences change
    When its position draft is committed
    Then the latest master gain, hidden flags, and crop insets are retained
