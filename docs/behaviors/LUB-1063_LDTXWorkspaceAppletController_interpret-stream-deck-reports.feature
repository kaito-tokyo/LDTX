# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1063 @LDTXWorkspaceAppletController
Feature: interpret stream deck reports

  @LUB-1063.1 @Unit
  Scenario: Dispatch one action at the intended key transition
    Given valid Stream Deck reports including held and repeated keys
    When reports are received
    Then immediate actions fire on key down and Start or Pause fires only on key up

  @LUB-1063.2 @Unit
  Scenario: Reject malformed or obsolete key transitions
    Given a held key and a changed target generation or malformed report
    When a release report arrives
    Then no action is sent to a different target and malformed input preserves held state

  @LUB-1063.3 @Unit
  Scenario: Frame image chunks without losing payload
    Given an image spanning one or more HID report payloads
    When image reports are generated
    Then chunk indices, final flags, lengths, and padding preserve the original image bytes
