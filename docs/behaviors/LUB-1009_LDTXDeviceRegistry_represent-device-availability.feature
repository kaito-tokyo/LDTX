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
  Scenario: Report disconnected assignments
    Given a saved device assignment absent from discovery
    When available devices are refreshed
    Then the assignment remains identifiable as unavailable

