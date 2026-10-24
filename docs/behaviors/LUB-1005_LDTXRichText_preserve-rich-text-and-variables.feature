# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1005 @LDTXRichText
Feature: LDTXRichText preserve rich text and variables

  @LUB-1005.1 @Integration
  Scenario: Round trip variable attachments
    Given valid RTFD with text formatting and variable attachments
    When the document is decoded and encoded
    Then formatting and variable identities are preserved

  @LUB-1005.2 @Integration
  Scenario: Reject malformed attachments
    Given RTFD containing an unsupported or malformed variable attachment
    When the document is validated
    Then validation fails instead of accepting an empty document

  @LUB-1005.3 @Integration
  Scenario: Expand values as literal text
    Given a document containing variable attachments and a value dictionary
    When the document is expanded
    Then known values are inserted literally and unresolved variables render empty

