# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1047 @LDTXWorkspaceAppletUI
Feature: save and reload current document

  @LUB-1047.1 @UIComponent
  Scenario Outline: Keep pending edits independent of persisted content
    Given saved content A and pending edits B
    When <operation> is performed
    Then pending edits remain B and the runtime baseline remains A

    Examples:
      | operation               |
      | capture a snapshot      |
      | write a staging copy    |

  @LUB-1047.2 @UIComponent
  Scenario Outline: Preserve content after an unsuccessful save
    Given saved content A and pending edits B
    When saving fails because <failure>
    Then the saved package and runtime baseline remain A and pending edits remain B

    Examples:
      | failure                 |
      | the ROI is invalid      |
      | the destination cannot be written |

  @LUB-1047.3 @UIComponent
  Scenario: Reload canonical content without adding Undo
    Given an open Workspace with pending edits and a readable saved package
    When the saved package is explicitly reloaded
    Then saved content replaces pending edits without creating an Undo action

  @LUB-1047.4 @UIComponent
  Scenario: Create an editable unsaved document
    Given a request for a new Workspace
    When the document is created before choosing a destination
    Then it has a unique external identity and editing is available
    And output remains unavailable until a successful save

  @LUB-1047.5 @UIComponent
  Scenario: Resolve unsaved Workspace changes when closing
    Given an open Workspace with unsaved changes
    When the user cancels or discards the close confirmation
    Then cancellation retains the open Workspace and its edits
    And discarding closes it after shutdown without saving the pending changes

  @LUB-1047.6 @UIComponent
  Scenario: Retain edits made after a save snapshot
    Given a background save has captured a Workspace snapshot
    When the Workspace is edited before that snapshot is written
    Then the saved package contains the snapshot and later edits remain pending

  @LUB-1047.7 @UIComponent
  Scenario: Restrict Revert during output
    Given a Workspace document that is open and editable
    When output becomes active
    Then Revert and browsing document versions are unavailable until output ends

  @LUB-1047.8 @UIComponent
  Scenario: Adopt a changed Workspace document location
    Given an open Workspace with location-specific local state
    When its document acquires a different URL
    Then the coordinator copies its local state to the new location
    And subsequent persistence operations use the new document URL
