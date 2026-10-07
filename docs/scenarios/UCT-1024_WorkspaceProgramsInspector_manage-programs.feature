# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
# SPDX-License-Identifier: Apache-2.0

@UCT-1024 @WorkspaceProgramsInspector
Feature: Manage Programs
  Rename and confirmed deletion are available for each Program while output is inactive.
  Cancelling either dialog leaves the Workspace unchanged.

  @UCT-1024.1 @WorkspaceStoreService
  Scenario: Rename validates all resource names and preserves rejected edits
    Given a Workspace contains named Programs, audio devices, video components, and Visions
    When a Program is renamed
    Then empty or duplicate names are rejected without changing the model
    And valid names are trimmed and saved
    And missing Programs and edits during output are rejected

  @UCT-1024.2 @WorkspaceWindowController @WorkspaceStoreService
  Scenario: Delete removes only the requested Program and its preferences
    Given a Workspace contains two Programs with saved preferences
    When the user confirms deletion of one Program
    Then the existing runtime removes that Program and both canvas preferences
    And the other Program remains available
    And deletion during output or of a missing Program is rejected
