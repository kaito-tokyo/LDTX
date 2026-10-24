# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1016 @LDTXYouTubeRTMPS
Feature: LDTXYouTubeRTMPS encode and publish media

  @LUB-1016.1 @Unit
  Scenario: Encode protocol packets
    Given supported audio or video metadata and payload
    When RTMP and FLV packets are encoded
    Then packet lengths, timestamps, and payload boundaries match the supplied media

  @LUB-1016.2 @Integration
  Scenario: Report transport failure
    Given an active publisher using a controllable transport
    When the transport fails
    Then the publisher reports failure rather than successful delivery

  @LUB-1016.3 @Unit
  Scenario: Validate stream configuration
    Given a missing or invalid stream key configuration
    When publishing configuration is prepared
    Then configuration fails before connecting

