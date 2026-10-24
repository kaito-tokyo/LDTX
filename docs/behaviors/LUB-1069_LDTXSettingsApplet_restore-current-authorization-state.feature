# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1069 @LDTXSettingsApplet
Feature: restore current authorization state

  @LUB-1069.1 @Integration
  Scenario: Keep stale account restore results out of current settings
    Given account restoration in progress for an older OAuth client
    When a different client is imported before restoration completes
    Then the older result cannot overwrite the current settings instance

  @LUB-1069.2 @Integration
  Scenario: Expose verified account status and lookup failures
    Given restored authorization and a controllable channel lookup
    When channel lookup succeeds, is empty, or fails
    Then the UI receives the verified channel identity or an actionable failure

  @LUB-1069.3 @Integration
  Scenario: Avoid authorization persistence in test modes
    Given settings running with a test-mode authorization provider
    When authorization state is initialized or changed
    Then real authorization is neither restored nor persisted
