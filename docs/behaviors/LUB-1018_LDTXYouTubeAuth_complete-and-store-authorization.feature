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

  @LUB-1018.2 @Unit
  Scenario Outline: Validate the authorization redirect address
    Given a listener URL with host <host>
    When the redirect address is validated
    Then validation <result>

    Examples:
      | host      | result                            |
      | 127.0.0.1 | returns the unchanged listener URL |
      | ::1       | rejects the listener URL           |

  @LUB-1018.3 @Integration
  Scenario: Preserve account storage boundaries
    Given stored authorization state in isolated test storage
    When the account is loaded or removed
    Then the requested state is restored or removed without touching other accounts

