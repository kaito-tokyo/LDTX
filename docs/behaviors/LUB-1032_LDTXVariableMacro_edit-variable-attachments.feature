# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1032 @LDTXVariableMacro
Feature: LDTXVariableMacro edit variable attachments

  @LUB-1032.1 @UIComponent
  Scenario: Insert and preserve variable chips
    Given a rich text editor and a selected variable
    When the variable is inserted and the document is exported as RTFD
    Then the exported attachment preserves the variable identity and formatting

  @LUB-1032.2 @UIComponent
  Scenario: Keep ordinary pasted text literal
    Given plain text that resembles a variable expression
    When the text is pasted
    Then the text remains literal instead of becoming a variable attachment

  @LUB-1032.3 @UIComponent
  Scenario: Preserve active text composition
    Given an editor with an active marked-text composition
    When an unchanged model update arrives
    Then the composition is not replaced

