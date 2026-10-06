# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1003 @WorkspaceDocument
Feature: Preserve edits during saving

  @UCT-1003.1 @WorkspaceWindowController
  Scenario: Edits synchronously update AppKit document change state
    Given a clean Workspace
    When its definition or preferences change and Save completes
    Then the edited state changes synchronously and successful Save clears it

  @UCT-1003.2 @WorkspaceWindowController
  Scenario: A queued save includes edits made before it starts
    Given a queued Workspace save that has not started
    When the user edits the Workspace before the queued operation begins
    Then the saved package includes those edits

  @UCT-1003.3 @WorkspaceWindowController
  Scenario: A captured background snapshot excludes later edits
    Given a Workspace whose background save snapshot has been captured
    When the Workspace is edited before the snapshot is written
    Then the saved package contains the snapshot and later edits remain unsaved

  @UCT-1003.4 @WorkspaceWindowController
  Scenario: Unsupported copy actions are disabled and save failures retain edits
    Given a Workspace with pending edits and an unwritable save destination
    When copy actions are validated and saving fails
    Then copy actions are unavailable and the pending edits remain in the Document

  @UCT-1003.5 @WorkspaceWindowController
  Scenario: Editing continues while a background save is pending
    Given a Workspace with a background save paused before writing
    When the user edits the Workspace while that save is pending
    Then editing completes without waiting for the save and the later edits remain pending
