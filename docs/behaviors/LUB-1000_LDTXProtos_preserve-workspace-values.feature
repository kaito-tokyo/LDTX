# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1000 @LDTXProtos
Feature: LDTXProtos preserve workspace values

  @LUB-1000.1 @Unit
  Scenario: Preserve rational representations
    Given a rational value with a nonzero denominator
    When the value is set and serialized
    Then its numerator and denominator are preserved without reduction

  @LUB-1000.2 @Unit
  Scenario: Keep field presence and unknown data
    Given a V4 message containing absent optional fields and unknown fields
    When the message is decoded and encoded
    Then absent fields remain absent and unknown fields survive

  @LUB-1000.3 @Unit
  Scenario: Reject an unrepresentable decimal without mutation
    Given a rational value and an unrepresentable decimal
    When the decimal is assigned
    Then the previous rational value is preserved

  @LUB-1000.4 @Unit
  Scenario: Preserve UUID byte order and absence
    Given a UUID stored in a protobuf envelope
    When its bytes are encoded or decoded
    Then valid UUIDs use RFC 9562 byte order
    And absent or invalid-length values do not become a different valid UUID

