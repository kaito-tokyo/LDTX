# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1049 @LDTXAppletSupport
Feature: preserve window local layout

  @LUB-1049.1 @UIComponent
  Scenario: Restore pane widths and content state
    Given a window with expanded panes and edited pane content
    When a pane is collapsed and expanded
    Then its expanded width and hosted content are retained

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
