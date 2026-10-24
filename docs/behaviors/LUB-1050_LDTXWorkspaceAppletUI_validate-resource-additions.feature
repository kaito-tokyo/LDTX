# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1050 @LDTXWorkspaceAppletUI
Feature: validate resource additions

  @LUB-1050.1 @UIComponent
  Scenario: Reject an invalid resource without editing the document
    Given an addition draft with a duplicate name, unavailable device, invalid dimensions, or unsupported Vision input
    When the draft is submitted
    Then the addition fails without changing the definition or selection

  @LUB-1050.2 @UIComponent
  Scenario: Add a resource using explicit selections
    Given an editable Workspace and a valid named resource draft
    When the addition is committed
    Then a new stable resource identity is created with the requested input and defaults without silently placing canvas layers

  @LUB-1050.3 @UIComponent
  Scenario: Keep candidate discovery separate from assignment
    Given a new or restored dynamic device selection
    When discovery updates its candidates
    Then no assignment changes until an explicit valid commit and removed candidates clear only the editing draft
