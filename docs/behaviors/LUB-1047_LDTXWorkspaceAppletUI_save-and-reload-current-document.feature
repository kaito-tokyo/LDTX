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
    Then editing is available while output remains unavailable until a successful save
