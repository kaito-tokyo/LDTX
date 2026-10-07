# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1017 @WorkspaceContentPane
Feature: Preserve preview and divider state

  @UCT-1017.1
  Scenario: Content reflects output failures through AppKit Observation
    Given a Content Pane connected to an observable store
    When the output failure message changes
    Then AppKit Observation updates the displayed message without manual refresh

  @UCT-1017.2
  Scenario: Video tabs and audio selection remain independent and Window local
    Given two Content Panes with independent state
    When video tabs and audio selection change in one Pane
    Then video and audio selections stay independent and the other Window state stays unchanged

  @UCT-1017.3
  Scenario: Window shutdown stops the owned Preview renderer
    Given a Window Controller with an owned Preview renderer
    When the Controller shuts down
    Then its Preview is paused and runtime connections are released

  @UCT-1017.4
  Scenario: Preview uses injected runtimes and its own Program selection
    Given a Preview connected to injected Program runtimes
    When the owning Window selects a Program
    Then the injected runtimes are used and another Window Program stays unchanged

  @UCT-1017.5
  Scenario: Preview selection and Divider position remain Window local
    Given two Content Panes
    When a Preview canvas is clicked and a Divider is moved
    Then only the owning Pane selection and Divider position change

  @UCT-1017.6
  Scenario: Divider state restores and preserves user-adjusted height
    Given a Content Pane with a persisted Divider position
    When the Pane opens and later resizes after a user drag
    Then the saved position restores and the user-adjusted upper height is preserved

  @UCT-1017.7
  Scenario: A new Workspace preserves its initial content size
    Given a newly created Workspace
    When its Window is displayed
    Then the initial Content size remains as configured

  @UCT-1017.8
  Scenario: Output status preserves failure information
    Given a Workspace store supplies output state to its Content
    When output moves from active local recording to a failed inactive state
    Then the store exposes the current flags and retains the failure message
