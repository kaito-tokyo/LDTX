# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1066 @LDTXWorkspaceAppletModel
Feature: validate output destinations

  @LUB-1066.1 @Unit
  Scenario: Preserve explicit destination choices until Start
    Given output settings with disabled destinations or a disconnected folder
    When settings are normalized
    Then the user's choice remains intact for Start-time validation rather than silently choosing another destination

  @LUB-1066.2 @Unit
  Scenario: Commit folder overrides atomically
    Given a request to enable or disable a recording folder override
    When the folder choice is committed or cancelled
    Then enabling requires a selected normalized folder and disabling clears the override

  @LUB-1066.3 @Integration
  Scenario: Check a local output directory without changing it
    Given an existing or missing recording destination
    When writability is probed
    Then usable directories remain unchanged and missing directories report unavailable

  @LUB-1066.4 @Unit
  Scenario: Reject unsupported encoding profiles
    Given a dual-canvas output configuration
    When the profile and bit rates are validated
    Then supported positive bit rates are accepted and unsupported profiles or nonpositive rates are rejected
