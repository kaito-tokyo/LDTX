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
  Scenario: The first save names an untitled Workspace and later Save As is unavailable
    Given an untitled Workspace
    When the Workspace is saved to a named package for the first time
    Then the package name becomes the Workspace name and subsequent Save As is unavailable

  @UCT-1002.3 @WorkspaceWindowController
  Scenario: The first save preserves an explicit Workspace name
    Given a new Workspace with an explicitly assigned name
    When the Workspace is saved to a differently named package
    Then the explicit Workspace name is preserved

  @UCT-1002.4 @WorkspaceWindowController
  Scenario: Creation shows windows only after saving succeeds
    Given a request to create a new Workspace package
    When initial saving succeeds or fails
    Then windows appear only after successful saving and failed creation releases the Document

  @UCT-1002.5 @WorkspaceWindowController
  Scenario: Autosave operations are disabled and rejected
    Given a Workspace with unsaved changes
    When an autosave operation is requested
    Then autosave is unavailable and the operation fails without writing the package

  @UCT-1002.6 @WorkspaceWindowController
  Scenario: Duplicate is disabled and creates no Document
    Given an open Workspace
    When the Duplicate action is validated and requested
    Then the action is unavailable and no duplicate Document is created
