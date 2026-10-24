# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1064 @LDTXWorkspaceAppletModel
Feature: allocate unique resource identities

  @LUB-1064.1 @Unit
  Scenario: Generate positive unique IDs against every resource kind
    Given a Workspace with existing resource IDs and a controlled clock and random source
    When new IDs are allocated across collisions or clock rollback
    Then each ID is positive and odd and does not reuse an existing or already issued ID

  @LUB-1064.2 @Unit
  Scenario: Wait only when an identity collides
    Given a deterministic ID generator with a repeated candidate
    When a second ID is requested
    Then collision waits reread the clock before returning a fresh ID
