# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1018 @PaneSplitViewController
Feature: Toggle side panes

  @UCT-1018.1
  Scenario: Sidebar expansion restores its previous width
    Given the sidebar has an established expanded width
    When the user repeatedly collapses and expands the sidebar
    Then the previous expanded width is restored

  @UCT-1018.2
  Scenario: Pane widths are persisted as numeric values
    Given a window has configured sidebar and inspector widths
    When the window encodes its pane state
    Then the archived values preserve the pane widths

  @UCT-1018.3
  Scenario: Inspector toggling changes visibility
    Given the inspector is expanded
    When the user toggles the inspector twice
    Then the inspector collapses and then expands
