# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1028 @LDTXWorkspaceAppletStore
Feature: LDTXWorkspaceAppletStore preserve preferences

  @LUB-1028.1 @Unit
  Scenario: Keep stored canvas preferences independent
    Given Landscape and Portrait preferences in a Program preferences store
    When the Landscape layer transform changes
    Then the Portrait layer transform and unrelated preferences remain unchanged

  @LUB-1028.2 @Integration
  Scenario: Restore application settings
    Given application settings in isolated storage
    When settings are saved and the store is recreated
    Then the saved settings are restored

  @LUB-1028.3 @Unit
  Scenario: Publish one revision per logical preference change
    Given a preferences store observed by runtime consumers
    When a setter or whole-value replacement changes its value
    Then the revision advances once for that logical change
    And equal updates or repeated removals do not advance the revision
