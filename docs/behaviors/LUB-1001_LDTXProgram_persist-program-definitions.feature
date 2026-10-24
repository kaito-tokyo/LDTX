# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1001 @LDTXProgram
Feature: LDTXProgram persist program definitions

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
  Scenario: Mute without discarding the configured gain
    Given an audio channel with gain 0.5
    When the channel is muted and then unmuted
    Then muting produces zero output gain and unmuting restores gain 0.5

  @LUB-1001.4 @Unit
  Scenario: Import a legacy uniform layer scale
    Given a saved layer destination with one uniform scale value
    When it is decoded into independent horizontal and vertical scales
    Then both axes retain that uniform scale

  @LUB-1001.5 @Unit
  Scenario: Keep resource references stable through Program edits
    Given named video layers and audio inputs referenced by multiple Programs
    When resources are reordered, renamed, or removed
    Then unaffected identities and preferences remain stable
    And stale references are removed without dropping unrelated generated audio

  @LUB-1001.6 @Unit
  Scenario: Bound audio channel gain
    Given a channel gain expressed in decibels or linear units
    When it is converted and stored
    Then the supported range is minus 80 through plus 20 decibels
    And stored gains are clamped to that range
