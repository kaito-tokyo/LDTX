# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1002 @WorkspaceDocument
Feature: Save and reopen

  @UCT-1002.1 @WorkspaceWindowController
  Scenario: Reopening restores saved Workspace and Preview state
    Given a new Workspace with configured Program and video content
    When the Workspace is saved, closed, and opened again
    Then the saved content is restored and the Preview reconnects

  @UCT-1002.2 @WorkspaceWindowController
  Scenario: SwiftUI manages document naming and Save As
    Given an untitled Workspace
    When the Workspace is saved to a named package for the first time
    Then SwiftUI manages the document filename and window title
    And the stored Workspace display name is not rewritten from the package name
    And Save As uses the standard DocumentGroup behavior

  @UCT-1002.3 @WorkspaceWindowController
  Scenario: The first save preserves an explicit Workspace name
    Given a new Workspace with an explicitly assigned name
    When the Workspace is saved to a differently named package
    Then the explicit Workspace name is preserved

  @UCT-1002.4 @WorkspaceWindowController
  Scenario: Creation opens an unsaved editable Workspace
    Given a request to create a new Workspace
    When the Document and its window are created
    Then editing is available without choosing a save destination
    And the Workspace has a unique external ID before saving
    And output remains unavailable until content is successfully saved

  @UCT-1002.5 @WorkspaceWindowController
  Scenario: Autosave operations are disabled and rejected
    Given a Workspace with unsaved changes
    When an autosave operation is requested
    Then autosave is unavailable and the operation fails without writing the package

  @UCT-1002.6 @WorkspaceWindowController
  Scenario: Duplicate uses the standard document behavior
    Given an open Workspace
    When the Duplicate action is validated and requested
    Then SwiftUI manages duplication through DocumentGroup
