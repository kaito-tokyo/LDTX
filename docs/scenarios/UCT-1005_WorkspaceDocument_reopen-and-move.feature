# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1005 @WorkspaceDocument
Feature: Reopen and move

  @UCT-1005.1 @WorkspaceWindowController
  Scenario: Opening the same URL reuses the registered Document
    Given a saved Workspace already registered with the Document Controller
    When the same package URL is opened again
    Then the registered Document is reused without requiring an exclusive package lock

  @UCT-1005.2 @WorkspaceWindowController
  Scenario: Restoration requires an existing Workspace package URL
    Given an existing Workspace package and missing or absent restoration URLs
    When the application attempts Document restoration
    Then the existing package can be restored and missing or absent URLs are rejected

  @UCT-1005.3 @WorkspaceWindowController
  Scenario: Workspace owns its Window Controller and uses standard restoration
    Given a Workspace with its Window Controller
    When the application encodes and restores the Window
    Then the controller remains owned by the Document and standard Document restoration is used

  @UCT-1005.4 @WorkspaceWindowController
  Scenario: Moving a presented Workspace preserves resources and rebinds local state
    Given an open Workspace with resources and path-specific local state
    When the presented package is moved to a new URL
    Then resources are preserved and local state is rebound to the new URL

  @UCT-1005.5 @WorkspaceWindowController
  Scenario: Moving a Workspace synchronizes its runtime URL
    Given an open Workspace with active owned runtimes
    When the package is moved
    Then the Document and runtime URLs match the new package URL
