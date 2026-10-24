# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1068 @LDTXWorkspaceAppletUI
Feature: reconcile live selection and meters

  @LUB-1068.1 @Unit
  Scenario: Keep device drafts separate from restored assignments
    Given a restored device assignment and unresolved dynamic candidates
    When discovery succeeds, fails, or removes a candidate
    Then display status reflects availability and discovery never selects or reassigns a device automatically

  @LUB-1068.2 @Unit
  Scenario: Restrict edits and Program switching by current state
    Given an output state that is idle, running, or transitioning
    When selection is validated
    Then only operations supported by that state are admitted and clearing a selection remains explicit

  @LUB-1068.3 @Unit
  Scenario: Display a bounded audio peak envelope
    Given audio peaks including sudden attacks, silence, and nonfinite values
    When the meter envelope advances
    Then attack is immediate, release decays with elapsed time, and invalid values cannot escape the display range
