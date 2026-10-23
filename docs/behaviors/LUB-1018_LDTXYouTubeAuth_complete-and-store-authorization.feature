# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1018 @LDTXYouTubeAuth
Feature: LDTXYouTubeAuth complete and store authorization

  @LUB-1018.1 @Unit
  Scenario: Reject a web application OAuth client
    Given Google OAuth client JSON with a web payload instead of an installed payload
    When the client configuration is decoded
    Then decoding fails with an unsupported client type error

  @LUB-1018.2 @Integration
  Scenario: Handle the loopback callback
    Given an authorization listener expecting a callback
    When a callback for that authorization arrives
    Then the authorization response is delivered to its waiting caller

  @LUB-1018.3 @Integration
  Scenario: Preserve account storage boundaries
    Given stored authorization state in isolated test storage
    When the account is loaded or removed
    Then the requested state is restored or removed without touching other accounts

