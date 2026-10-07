# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1016 @WorkspaceWindowController
Feature: Keep window controls local

  @UCT-1016.1
  Scenario: Operations fail safely when a runtime is unavailable
    Given a store with no runtime
    When output, Program selection, and screenshot operations are requested
    Then operations fail safely and capture synchronization returns no failures

  @UCT-1016.2
  Scenario: Program choices are laid out vertically
    Given multiple Programs in the Workspace definition
    When the Program inspector lays out its selection controls
    Then Program radio controls form a vertical list

  @UCT-1016.3
  Scenario: An empty Program selector remains visible
    Given an empty Workspace Program list
    When the Program selector is displayed
    Then it contains visible empty-state content

  @UCT-1016.4
  Scenario: Program selection resolves current definitions without rewriting restored IDs
    Given restored Program IDs and a current definition
    When the selection is resolved and changed
    Then current definitions are used without rewriting unresolved saved IDs

  @UCT-1016.5
  Scenario: Sidebar selection starts empty and remains Window local
    Given two Workspace Windows with separate stores
    When a Sidebar item is selected in one Window
    Then initial selection is empty and the other Window selection remains unchanged

  @UCT-1016.6
  Scenario: Physical assignments change only on explicit valid selection
    Given a saved physical device assignment and an editing draft
    When an explicit valid assignment is committed
    Then the saved assignment is display-only before commit and invalid selection cannot replace it

  @UCT-1016.7
  Scenario: Toolbar pane toggles restore widths in their own Window
    Given two open Workspace Windows
    When the Sidebar and Inspector are toggled in one Window
    Then the previous widths restore and the other Window remains unchanged

  @UCT-1016.8
  Scenario: Output buttons reflect state and invoke their own runtime
    Given a Workspace Window connected to a controllable runtime
    When output transitions succeed or fail and output buttons are used
    Then buttons reflect the current state and dispatch actions to that Window runtime

  @UCT-1016.9
  Scenario: Screenshot actions remain available outside local recording
    Given a Workspace Window whose output may or may not be a local recording
    When screenshot actions are validated and invoked
    Then screenshot actions remain enabled regardless of recording state

  @UCT-1016.10
  Scenario: Program selection updates only the owning Window runtimes
    Given two Window runtimes with independent Program selections
    When one Window selects another Program
    Then only its owned runtimes update and the selection remains Window local

  @UCT-1016.11
  Scenario: Shared device assignments update open Windows and stop after shutdown
    Given two open Windows sharing physical assignments
    When assignments change and one Window shuts down
    Then both live Windows update while the shut-down Window stops observing

  @UCT-1016.12
  Scenario: Dock badges follow registered Documents
    Given registered Workspace Documents
    When Documents are registered and removed
    Then the Dock badge follows the registered document count

  @UCT-1016.13
  Scenario: Sidebar additions affect their own Document and persist only on Save
    Given two Workspace Documents
    When resources are added through one Sidebar and the Document is saved
    Then only that Document changes and its additions persist only after Save

  @UCT-1016.14
  Scenario: Sidebar Preview uses its provided state
    Given a Sidebar Preview state is available
    When the Sidebar is created from that state
    Then its Workspace name and view content use the supplied state

  @UCT-1016.15
  Scenario: Sidebar additions require a live Document
    Given a Sidebar has Preview state without a live Document
    When an audio device, video component, or Vision addition is requested
    Then addition fails without changing definitions, selection, or physical assignments

  @UCT-1016.16 @WorkspaceWindow
  Scenario: Screenshot results use a transient popover without changing output state
    Given a Workspace is recording locally
    When screenshot capture fails
    Then a transient popover appears at the screenshot toolbar item
    And the output session failure state remains unchanged
    When capture succeeds
    Then the popover displays the number of saved Program screenshots
    And it shows only the Landscape file icon and name
    And the files can be opened or dragged to another destination
    And VFX Source screenshots are excluded from the file list
    And the output session failure state remains unchanged
    When the Window closes
    Then the screenshot popover closes
