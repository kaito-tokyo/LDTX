# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1007 @VideoLayersEditor
Feature: Follow selected program

  @UCT-1007.1
  Scenario: Preview constraints preserve editor size
    Given an Editor is constrained to its preview size
    When the layer content is populated
    Then the imposed Editor fitting size remains unchanged

  @UCT-1007.2
  Scenario: Editor rows use available width
    Given a layer Editor has multiple rows in a Window
    When the Editor lays out at the available width
    Then all rows fit the editor content height without an internal scroll view

  @UCT-1007.3
  Scenario: Editor owns observation without loading view until used
    Given an Editor is initialized but its view has not loaded
    When it is displayed and the layer list changes
    Then view creation remains lazy and Observation updates the displayed layers

  @UCT-1007.4
  Scenario: Hidden video tab uses latest state when shown
    Given Landscape and Portrait editors occupy separate tabs
    When Portrait membership changes while its tab is hidden and the tab is selected
    Then the Portrait table displays the latest layer list

  @UCT-1007.5
  Scenario: Editor reuses rows and refreshes save connections
    Given an Editor has rows with draft state and a commit callback
    When order and callbacks change before the draft is submitted
    Then rows are reused with the latest callback and a geometry change replaces incompatible rows

  @UCT-1007.6
  Scenario: Resolves and updates names from definition
    Given layers reference existing and missing Video Components
    When a component display name changes
    Then the reused row shows the current name and missing references have an explicit label

  @UCT-1007.7
  Scenario: Changing program discards transform draft
    Given a layer row has an unconfirmed transform
    When the selected Program identity changes
    Then the old row is replaced and its draft is discarded
