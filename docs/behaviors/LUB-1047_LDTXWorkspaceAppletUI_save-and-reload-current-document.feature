# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1047 @LDTXWorkspaceAppletUI
Feature: save and reload current document

  @LUB-1047.1 @UIComponent
  Scenario: Keep unsaved edits independent of the persisted baseline
    Given a Workspace with saved content A and pending edits B
    When a snapshot is captured or a staging copy is written
    Then pending edits remain B and the canonical saved baseline remains A

  @LUB-1047.2 @UIComponent
  Scenario: Validate before replacing saved content
    Given a Workspace whose pending content is invalid or whose write fails
    When a save is attempted
    Then the saved package and runtime baseline remain unchanged and pending edits remain available

  @LUB-1047.3 @UIComponent
  Scenario: Reload canonical content without adding Undo
    Given an open Workspace with pending edits and a readable saved package
    When the saved package is explicitly reloaded
    Then saved content replaces pending edits without creating an Undo action

  @LUB-1047.4 @UIComponent
  Scenario: Create an editable unsaved document
    Given a request for a new Workspace
    When the document is created before choosing a destination
    Then editing is available while output remains unavailable until a successful save
