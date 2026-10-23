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
  Scenario: Reuse the mask until a significant image change
    Given a completed mask and a stable input frame
    When the input is evaluated again
    Then the existing mask is reused without another inference
    But a sufficiently large spatially supported image change requests a new inference

