# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1001 @LDTXCorelibs
Feature: LDTXCorelibs persist program definitions

  @LUB-1001.1 @Unit
  Scenario: Round trip ordered Program content
    Given a composite Program with ordered video steps and audio channels
    When the definition is encoded and decoded
    Then step order, component settings, and audio channels are preserved

  @LUB-1001.2 @Unit
  Scenario: Keep layer visibility local to its Program
    Given Programs A and B sharing a camera layer
    When the layer is hidden in Program A
    Then the layer remains visible in Program B

  @LUB-1001.3 @Unit
  Scenario Outline: Apply mute without discarding the configured gain
    Given an audio channel with configured gain 0.5
    When its mute state is set to <muted>
    Then its output gain is <outputGain> and its configured gain remains 0.5

    Examples:
      | muted | outputGain |
      | true  | 0          |
      | false | 0.5        |

  @LUB-1001.4 @Unit
  Scenario: Import a legacy uniform layer scale
    Given a saved layer destination with one uniform scale value
    When it is decoded into independent horizontal and vertical scales
    Then both axes retain that uniform scale

  @LUB-1001.5 @Unit
  Scenario Outline: Update only affected resource references
    Given Programs referencing a camera and unrelated content
    When the camera reference is <change>
    Then <result> and unrelated content remains intact

    Examples:
      | change               | result                                      |
      | renamed              | the existing preferences follow the new name |
      | removed              | references to the removed camera disappear  |
      | removed from Program A | Program B retains its reference           |

  @LUB-1001.6 @Unit
  Scenario Outline: Convert supported decibel boundaries to linear gain
    Given an audio channel gain of <decibels> decibels
    When the gain is converted to linear units
    Then the result is <linear>

    Examples:
      | decibels | linear |
      | -80      | 0.0001 |
      | 0        | 1      |
      | 20       | 10     |

  @LUB-1001.7 @Unit
  Scenario: Clamp a stored audio gain
    Given a channel with a requested gain above the supported maximum
    When the channel gain is stored in Program preferences
    Then the stored linear gain is limited to plus 20 decibels
