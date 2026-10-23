# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1010 @LDTXBackgroundSegmentation
Feature: LDTXBackgroundSegmentation gate inference results

  @LUB-1010.1 @Integration
  Scenario: Distinguish preparation from a usable mask
    Given a background-removal preprocessor whose model is preparing
    When a frame is submitted
    Then the result reports preparing instead of a completed alpha mask

  @LUB-1010.2 @Integration
  Scenario: Reject stale inference publication
    Given an inference request from a superseded generation
    When that request finishes
    Then its result is not published as the current mask

