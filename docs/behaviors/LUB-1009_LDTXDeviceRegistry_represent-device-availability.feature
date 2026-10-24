# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1009 @LDTXDeviceRegistry
Feature: LDTXDeviceRegistry represent device availability

  @LUB-1009.1 @Unit
  Scenario: Preserve stable device identity
    Given an audio input with a persistent device UID
    When discovery updates its display information
    Then the logical identity remains the device UID

  @LUB-1009.2 @Integration
  Scenario: Expose discovery failure
    Given audio input discovery fails
    When the registry refreshes
    Then the audio input list is empty and the discovery error is available
    And the registry records that a refresh was attempted

