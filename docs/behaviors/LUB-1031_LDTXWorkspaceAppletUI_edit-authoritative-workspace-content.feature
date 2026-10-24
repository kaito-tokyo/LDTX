# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1031 @LDTXWorkspaceAppletUI
Feature: LDTXWorkspaceAppletUI edit authoritative workspace content

  @LUB-1031.1 @UIComponent
  Scenario: Undo a compound edit
    Given an editable Workspace and its document UndoManager
    When a compound edit is performed and undone
    Then the complete prior document content is restored

  @LUB-1031.2 @UIComponent
  Scenario: Keep invalid drafts out of saved values
    Given an inspector with an incomplete numeric draft
    When the draft is edited
    Then the last accepted document value is preserved until input is representable

  @LUB-1031.3 @UIComponent
  Scenario: Lock configuration during output
    Given a Workspace with active output
    When configuration controls are inspected
    Then configuration edits are disabled while supported runtime actions remain available

