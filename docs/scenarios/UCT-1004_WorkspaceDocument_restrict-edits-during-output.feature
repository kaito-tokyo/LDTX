# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1004 @WorkspaceDocument
Feature: Restrict edits during output

  @UCT-1004.1 @WorkspaceWindowController
  Scenario: Output permits only layer permutations and saves the latest order
    Given a Workspace with active output and existing video layers
    When the user reorders those layers and tries to add or replace a layer
    Then only permutations of the existing layers are accepted and saving preserves the latest order

  @UCT-1004.2 @WorkspaceWindowController
  Scenario: Starting output does not save pending edits
    Given a saved Workspace with pending model edits
    When the user starts output
    Then the package remains unchanged and the pending edits are retained

  @UCT-1004.3 @WorkspaceWindowController
  Scenario: Output freezes definition while preferences remain editable
    Given a clean Workspace whose output is active
    When the user changes its definition and its mix preferences
    Then the definition change is rejected while preferences update the edited state

  @UCT-1004.4 @WorkspaceWindowController
  Scenario: Output disables Save As and Revert
    Given a Workspace with active output
    When Save As and Revert menu actions are validated
    Then both actions are unavailable
