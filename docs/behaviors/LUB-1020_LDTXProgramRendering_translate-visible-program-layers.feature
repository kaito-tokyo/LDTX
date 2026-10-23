# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1020 @LDTXProgramRendering
Feature: LDTXProgramRendering translate visible program layers

  @LUB-1020.1 @Integration
  Scenario: Respect saved layer order
    Given visible layers listed from top to bottom as A, B, and C
    When its composition is prepared
    Then drawing commands are emitted in order C, B, A so A appears on top

  @LUB-1020.2 @Integration
  Scenario: Leave an unprepared overlay transparent
    Given a Clock layer without a completed retained texture
    When its drawing commands are prepared
    Then the Clock emits no placeholder pixels
    And a completed retained texture is used when it becomes available

