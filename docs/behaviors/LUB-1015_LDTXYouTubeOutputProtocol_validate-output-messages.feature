# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1015 @LDTXYouTubeOutputProtocol
Feature: LDTXYouTubeOutputProtocol validate output messages

  @LUB-1015.1 @Unit
  Scenario: Round trip output messages
    Given an output message with session identity and media metadata
    When the message is encoded and decoded
    Then the session identity and media metadata are preserved

  @LUB-1015.2 @Unit
  Scenario: Reject stale session messages
    Given an active session and a message from a retired session
    When the message is validated
    Then the stale message cannot advance the active session

