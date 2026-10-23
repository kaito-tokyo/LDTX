# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1007 @LDTXAudioEngine
Feature: LDTXAudioEngine deliver and stop audio

  @LUB-1007.1 @Unit
  Scenario: Keep logical routes independent
    Given two logical audio routes sharing one physical input
    When one route's gain or subscription changes
    Then the other route keeps its configured delivery

  @LUB-1007.2 @Integration
  Scenario: Fence delivery on unsubscribe
    Given an audio subscription with an in-flight callback
    When unsubscribe completes
    Then no later callback reaches that subscriber

  @LUB-1007.3 @Integration
  Scenario: Isolate a stalled consumer
    Given active audio monitoring and an output consumer that stalls
    When audio processing continues
    Then monitoring continues without waiting for the stalled output consumer

