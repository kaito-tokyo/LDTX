# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1067 @LDTXProgramRuntime
Feature: bound and convert output media

  @LUB-1067.1 @Integration
  Scenario: Isolate slow output subscribers
    Given multiple consumers of a shared ordered audio and video channel
    When one consumer stalls or exceeds its pending limit
    Then other consumers continue and the affected subscriber drains accepted events before closing

  @LUB-1067.2 @Integration
  Scenario: Preserve media format and high-resolution timestamps for RTMPS
    Given supported H264 or AAC samples
    When they are converted for RTMPS output
    Then codec configuration, timestamps, and payload boundaries survive while malformed or unsupported formats fail
