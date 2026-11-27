# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1074 @LDTXCorelibs
Feature: Describe errors for public logs

  @LUB-1074.1 @Unit
  Scenario Outline: Name the failing error without its private content
    Given a <error> whose associated value or user info contains a private path
    When its public diagnostic is created
    Then the diagnostic names <identity>
    And the private path is absent

    Examples:
      | error                                 | identity                              |
      | Swift enum case with a payload        | the type and case                     |
      | payload-free Swift enum case          | the type and case                     |
      | error with a custom description       | the type only                         |
      | Swift error bridged to NSError        | the type and code                     |
      | system NSError with an underlying one | each domain and code                  |
      | NSError with an unknown domain        | the code with a redacted domain       |

  @LUB-1074.2 @Unit
  Scenario: Publish only identifier details supplied by the implementation
    Given errors whose implementation supplies a protocol phase or a path as detail
    When their public diagnostics are created
    Then the protocol phase is included and the path is dropped
