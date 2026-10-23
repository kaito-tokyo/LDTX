# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1028 @LDTXWorkspaceAppletStore
Feature: LDTXWorkspaceAppletStore preserve preferences

  @LUB-1028.1 @Unit
  Scenario: Keep canvas preferences independent
    Given stored preferences for two canvases
    When one canvas preference changes
    Then the other canvas retains its stored values

  @LUB-1028.2 @Integration
  Scenario: Restore application settings
    Given application settings in isolated storage
    When settings are saved and the store is recreated
    Then the saved settings are restored

