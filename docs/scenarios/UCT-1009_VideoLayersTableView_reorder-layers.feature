# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1009 @VideoLayersTableView
Feature: Reorder layers

  @UCT-1009.1
  Scenario: Uses standard row dragging
    Given Video Layers are displayed in a SwiftUI List
    And each row has a reorder handle that enables moving while hovered
    When a row is dragged from its handle to another insertion position
    Then the standard List insertion indicator shows the destination

  @UCT-1009.2
  Scenario: Standard moves preserve membership
    Given a list contains three layers
    When one or more rows are moved with the standard onMove action
    Then the requested permutation is saved without changing layer membership

  @UCT-1009.3
  Scenario: Supports end insertion
    Given a layer is dragged to the end of the List
    When SwiftUI supplies the end insertion offset
    Then the layer becomes the last row

  @UCT-1009.4
  Scenario: One List scrolls the editors and layers
    Given audio editors and Video Layers share one List
    When membership, ordering, and container width change
    Then retained row state is reused and the List manages scrolling and width

  @UCT-1009.5
  Scenario: Mixed membership and order updates keep retained rows
    Given a retained layer row contains an unconfirmed draft
    When membership and order change repeatedly until the list is empty
    Then retained rows keep their drafts and table placement matches every updated list

  @UCT-1009.6
  Scenario: Failed order commit preserves the saved order
    Given a list has a failing order commit callback
    When a layer is moved to a new position
    Then the saved order is unchanged and the failure is reported
