# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1050 @LDTXWorkspaceAppletUI
Feature: validate resource additions

  @LUB-1050.1 @UIComponent
  Scenario Outline: Reject invalid resource addition without editing the document
    Given an addition draft with <invalidCondition>
    When the draft is submitted
    Then addition fails without changing the definition or selection

    Examples:
      | invalidCondition        |
      | a duplicate name        |
      | no selected device      |
      | an unavailable device   |
      | zero camera width       |
      | a generated Vision input |

  @LUB-1050.2 @UIComponent
  Scenario: Add a resource using explicit selections
    Given an editable Workspace and a valid named resource draft
    When the addition is committed
    Then a new stable resource identity is created with the requested input and defaults without silently placing canvas layers

  @LUB-1050.3 @UIComponent
  Scenario Outline: Keep candidate discovery separate from assignment
    Given a restored device assignment
    When discovery <change>
    Then the saved assignment is unchanged
    And the editing draft is <draft>

    Examples:
      | change                  | draft     |
      | lists the assigned device | retained |
      | removes the chosen candidate | cleared |

  @LUB-1050.4 @UIComponent
  Scenario Outline: Resolve an added audio device's display name
    Given an available audio device named "Microphone"
    When the addition draft supplies name <input>
    Then the new audio input is named "<expected>" and becomes the Inspector selection

    Examples:
      | input       | expected   |
      | ""          | Microphone |
      | "  Voice  " | Voice      |

  @LUB-1050.5 @UIComponent
  Scenario Outline: Admit resource additions only in editable output states
    Given output state <state>
    When a valid solid-color addition draft is validated
    Then addition is allowed <allowed>

    Examples:
      | state     | allowed |
      | idle      | true    |
      | paused    | true    |
      | failed    | true    |
      | starting  | false   |
      | recording | false   |
      | pausing   | false   |
      | stopping  | false   |

  @LUB-1050.6 @UIComponent
  Scenario: Rename a Program using a valid unique resource name
    Given a Workspace containing Programs and other named resources
    When a Program is renamed
    Then valid names are trimmed and accepted
    And empty, duplicate, missing, or output-locked edits leave the model unchanged

  @LUB-1050.7 @UIComponent
  Scenario: Delete the requested Program and its preferences
    Given a Workspace containing two Programs and their preferences
    When deletion of one Program is confirmed
    Then that Program and its canvas preferences are removed while the other remains
    And output or a missing Program prevents deletion without editing the document

  @LUB-1050.8 @UIComponent
  Scenario: Require a live document for Sidebar additions
    Given a Sidebar without a live Workspace document
    When adding an audio device, Video Component, or Vision is requested
    Then addition fails without changing the definition, selection, or device assignments
