# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1049
Feature: preserve window local layout

  @LUB-1049.1 @UIComponent
  Scenario Outline: Retain content while a side pane is hidden
    Given a <pane> pane with an active editing draft
    When that pane is collapsed and expanded
    Then its hosted draft and accepted task results remain available

    Examples:
      | pane      |
      | sidebar   |
      | inspector |

  @LUB-1049.2 @UIComponent
  Scenario: Keep controls within their window
    Given two Workspace windows with independent selection and controls
    When a selection, toolbar action, or layout preference changes in one window
    Then the action reaches that window's owner without changing the other window's local state

  @LUB-1049.3 @UIComponent
  Scenario: Respect content size constraints
    Given a window whose panes have natural minimum sizes
    When panes or preview geometry change
    Then minimum window size and scrollable editor content remain consistent with visible panes

  @LUB-1049.4 @UIComponent
  Scenario: Restore the Sidebar's expanded width
    Given a Sidebar expanded to 280 pixels
    When it is collapsed and expanded
    Then its width returns to 280 pixels without allowing collapse from window resizing

  @LUB-1049.5 @UIComponent
  Scenario: Keep an empty Program selector visible
    Given a Workspace without Programs
    When its Program selector is displayed
    Then it shows an empty state

  @LUB-1049.6 @UIComponent
  Scenario: Stop observing shared device assignments after shutdown
    Given two open Workspace windows observing shared device assignments
    When assignments change after one window shuts down
    Then the remaining window updates and the shut-down window does not

  @LUB-1049.7 @UIComponent
  Scenario: Indicate active output in the Dock
    Given multiple registered Workspace coordinators
    When output starts or stops in their Workspaces
    Then the Dock shows REC while at least one registered Workspace has active output
    And the badge clears after all registered Workspaces stop

  @LUB-1049.8 @UIComponent
  Scenario: Arrange Program choices vertically
    Given a Workspace with multiple Programs
    When the Program selector is displayed
    Then its choices are arranged vertically

  @LUB-1049.9 @UIComponent
  Scenario: Resolve a missing saved Program without rewriting its ID
    Given a saved Program selection that is absent from the current definition
    When the Program selector resolves the current selection
    Then it displays a valid current Program if one exists
    And the saved selection is not silently rewritten

  @LUB-1049.10 @UIComponent
  Scenario: Reject Program selection without a runtime
    Given a Program inspector without a connected runtime
    When a Program is selected
    Then selection fails without changing the saved selection
