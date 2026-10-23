# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1040 @LDTXYouTubeOutputServiceProcess
Feature: LDTXYouTubeOutputServiceProcess isolate output media processing

  @LUB-1040.1 @XPC
  Scenario: Reach the embedded service
    Given the application host containing the output XPC service
    When the client establishes a connection and sends a minimal request
    Then the embedded service responds through the process boundary

  @LUB-1040.2 @Integration
  Scenario: Reject retired session media
    Given a media processor with an active session
    When media for an earlier session is submitted
    Then the earlier session cannot modify the active output

