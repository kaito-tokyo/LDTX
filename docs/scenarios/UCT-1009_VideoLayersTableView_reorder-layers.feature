# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1009 @VideoLayersTableView
Feature: Reorder layers

  @UCT-1009.1
  Scenario: Uses standard row dragging
    Given a table row has a designated top drag band
    When drag eligibility is checked inside and outside that band
    Then only the top band permits a row drag

  @UCT-1009.2
  Scenario: Accepts single local moves and rejects foreign
    Given a table contains three layers
    When local, foreign, missing, and invalid-position drops are attempted
    Then valid single local moves produce the requested permutations and invalid drops are rejected

  @UCT-1009.3
  Scenario: Lower half of last row targets end insertion
    Given a dragged layer targets the lower half of the last row
    When the proposed insertion location is resolved
    Then the drop inserts after the last row while an upper-half drop inserts before it

  @UCT-1009.4
  Scenario: Container scrolls independently and updates rows in place
    Given a table is embedded in an external scroll container
    When membership, ordering, and container width change
    Then retained rows are reused and table width follows the external container

  @UCT-1009.5
  Scenario: Mixed membership and order updates keep retained rows
    Given a retained layer row contains an unconfirmed draft
    When membership and order change repeatedly until the list is empty
    Then retained rows keep their drafts and table placement matches every updated list

  @UCT-1009.6
  Scenario: Failed order commit does not accept drop
    Given a table has a failing order commit callback
    When a layer is dropped at a new position
    Then the drop is rejected, order is unchanged, and the failure is reported
