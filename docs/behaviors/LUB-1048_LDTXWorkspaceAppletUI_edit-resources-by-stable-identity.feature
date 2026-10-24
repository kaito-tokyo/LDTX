# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1048 @LDTXWorkspaceAppletUI
Feature: edit resources by stable identity

  @LUB-1048.1 @UIComponent
  Scenario Outline: Keep fill edits attached to their resource
    Given a <kind> Inspector for internal ID 11 beside another component with ID 21
    When the name for ID 11 is edited to "Renamed"
    Then ID 11 is named "Renamed" and ID 21 is unchanged

    Examples:
      | kind            |
      | solid           |
      | linearGradient  |
      | radialGradient  |
      | conicGradient   |

  @LUB-1048.2 @UIComponent
  Scenario: Edit layers without changing unrelated content
    Given independent Program canvases with layer preferences
    When a layer's visibility is changed in one Program canvas
    Then only that layer's visibility changes

  @LUB-1048.3 @UIComponent
  Scenario Outline: Reject deletion of a referenced component
    Given a component referenced by a <vision> Vision
    When deletion is requested
    Then the component and its references remain unchanged

    Examples:
      | vision        |
      | OCR           |
      | SceneDetector |

  @LUB-1048.4 @UIComponent
  Scenario Outline: Commit supported outline widths and preserve invalid drafts
    Given a Clock outline with saved width <saved>
    When the width field receives "<input>"
    Then its draft remains "<input>" and its document width is <expected>

    Examples:
      | saved | input      | expected |
      | 1     | 3          | 3        |
      | 3     | 3.         | 3        |
      | 1     | 3.5        | 3.5      |
      | 1     | 0          | 0        |
      | 1     | 64         | 64       |
      | 1     | 65         | 1        |
      | 1     | 100        | 1        |
      | 1     | -1         | 1        |
      | 1     | 1/0        | 1        |
      | 1     | 2147483648 | 1        |
      | 1     |            | 1        |
      | 100   | 65         | 100      |
      | 100   | 64         | 64       |

  @LUB-1048.5 @UIComponent
  Scenario Outline: Derive name submission from the normalized input
    Given a name dialog where "Taken" is unavailable
    When its input is <input>
    Then its candidate is "<candidate>" and submission is <allowed>

    Examples:
      | input           | candidate | allowed |
      | "  Camera  \n" | Camera    | true    |
      | " \n  "        |           | false   |
      | " Taken \n"    | Taken     | false   |

  @LUB-1048.6 @UIComponent
  Scenario Outline: Commit master volume in tenths of a decibel
    Given a master volume of -12 decibels
    When the field receives "<input>"
    Then its document numerator is <numerator> with denominator 10
    And the input is <accepted>

    Examples:
      | input  | numerator | accepted |
      | -12.04 | -120      | true     |
      | -80    | -800      | true     |
      | 20     | 200       | true     |
      | -      | -120      | false    |
      | 100    | -120      | false    |
      | -81    | -120      | false    |
      | 20.1   | -120      | false    |
      | inf    | -120      | false    |

  @LUB-1048.7 @UIComponent
  Scenario Outline: Commit only the edited transform field
    Given an editable layer on a 1920 by 1080 canvas
    When field <field> receives "<input>"
    Then its value is <numerator> divided by <denominator> and other fields are unchanged

    Examples:
      | field        | input | numerator | denominator |
      | translationX | 960   | 960       | 1920        |
      | translationY | 270   | 270       | 1080        |
      | scaleX       | -1.25 | -125      | 100         |
      | scaleY       | 2     | 2         | 1           |

  @LUB-1048.8 @UIComponent
  Scenario Outline: Move layers only within a current Program
    Given layer IDs 1, 2, 3 and Program presence <programPresent>
    When source indices <source> move to offset <destination>
    Then stored layer IDs are <expected>

    Examples:
      | source | destination | programPresent | expected |
      | 2      | 0           | true           | 3, 1, 2  |
      | 0      | 3           | true           | 2, 3, 1  |
      | 0, 1   | 3           | true           | 3, 1, 2  |
      | 99     | 0           | true           | 1, 2, 3  |
      | 0      | 99          | true           | 1, 2, 3  |
      | 0      | 3           | false          | 1, 2, 3  |

  @LUB-1048.9 @UIComponent
  Scenario Outline: Preserve content when deletion is unavailable
    Given component 10 with output active <outputActive> and document closed <closed>
    When deletion of <targetID> is requested
    Then document content is unchanged

    Examples:
      | outputActive | closed | targetID |
      | true         | false  | 10       |
      | false        | true   | 10       |
      | false        | false  | 999      |

  @LUB-1048.10 @UIComponent
  Scenario: Preserve an incomplete transform draft while editing another field
    Given a layer with an incomplete X position draft "-"
    When its Y scale is edited to 0.5
    Then the X position stays unchanged and its draft remains "-"
    And the Y scale is committed as 0.5

  @LUB-1048.11 @UIComponent
  Scenario Outline: Validate integer drafts and values by numeric type
    Given signed Int32 and unsigned UInt32 fields
    When the input is "<input>"
    Then signed draft acceptance is <signedDraft> and value acceptance is <signedValue>
    And unsigned draft acceptance is <unsignedDraft> and value acceptance is <unsignedValue>

    Examples:
      | input       | signedDraft | unsignedDraft | signedValue | unsignedValue |
      |             | true        | true          | false       | false         |
      | 0           | true        | true          | true        | true          |
      | 0001        | true        | true          | true        | true          |
      | -           | true        | false         | false       | false         |
      | -1          | true        | false         | true        | false         |
      | 2147483647  | true        | true          | true        | true          |
      | 2147483648  | false       | true          | false       | true          |
      | -2147483648 | true        | false         | true        | false         |
      | -2147483649 | false       | false         | false       | false         |
      | 4294967295  | false       | true          | false       | true          |
      | 4294967296  | false       | false         | false       | false         |
      | 1.5         | false       | false         | false       | false         |
      | 1/2         | false       | false         | false       | false         |
      | +1          | false       | false         | false       | false         |
      | １２        | false       | false         | false       | false         |
      | 1 2         | false       | false         | false       | false         |
      | 12px        | false       | false         | false       | false         |
      | 1\n         | false       | false         | false       | false         |

  @LUB-1048.12 @UIComponent
  Scenario Outline: Accept only ASCII digit drafts
    Given a Rational32 digit field
    When the input is "<input>"
    Then draft and final acceptance are <accepted>
    And accepted values preserve the input text

    Examples:
      | input | accepted |
      |       | true     |
      | 0     | true     |
      | 1920  | true     |
      | 0001  | true     |
      | -1    | false    |
      | +1    | false    |
      | 1.5   | false    |
      | 1/2   | false    |
      | １２  | false    |
      | 12px  | false    |
      | 1 2   | false    |
      | 12\n  | false    |

  @LUB-1048.13 @UIComponent
  Scenario Outline: Reset outline drafts after a membership change
    Given two outline widths 1 and <secondWidth> with an invalid draft in the first field
    When outline <removedIndex> is removed
    Then the obsolete field loses focus and the remaining field displays its saved width

    Examples:
      | secondWidth | removedIndex |
      | 1           | 0            |
      | 1           | 1            |
      | 2           | 0            |
      | 2           | 1            |

  @LUB-1048.14 @UIComponent
  Scenario Outline: Reject unavailable outline edits
    Given a Clock Inspector with output active <outputActive>, document closed <closed>, and component present <present>
    When an outline edit is requested
    Then the document content remains unchanged

    Examples:
      | outputActive | closed | present |
      | true         | false  | true    |
      | false        | true   | true    |
      | false        | false  | false   |
