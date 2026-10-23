# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1012 @LDTXMediaTiming
Feature: LDTXMediaTiming maintain audio timelines

  @LUB-1012.1 @Integration
  Scenario: Advance timestamps by sample count
    Given an audio clock with a configured sample rate
    When successive audio frames are timestamped
    Then presentation timestamps advance according to consumed samples

  @LUB-1012.2 @Integration
  Scenario: Handle discontinuities explicitly
    Given an audio channel timeline with a discontinuity
    When a new timing interval is accepted
    Then the resulting timeline follows the declared discontinuity policy without backward presentation time

