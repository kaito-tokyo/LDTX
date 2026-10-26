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
