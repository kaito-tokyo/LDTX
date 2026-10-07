# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1000 @WorkspaceDocument
Feature: Workspace close confirmation with unsaved changes

  @UCT-1000.1 @WorkspaceWindowController
  Scenario: Cancel closing preserves unsaved changes
    Given a Workspace is open with unsaved changes
    When the user closes the Workspace and selects Cancel in the confirmation sheet
    Then the Workspace remains open
    And its unsaved changes are preserved

  @UCT-1000.2 @WorkspaceWindowController
  Scenario: Discard closes without saving pending changes
    Given a Workspace is open with unsaved changes
    When the user closes the Workspace and selects Don't Save in the confirmation sheet
    Then closure is allowed after Workspace shutdown completes
    And the Workspace window closes
    And the saved Workspace still contains the previously saved changes
