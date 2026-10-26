# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1004 @Workspace
Feature: convert Workspace values for platform use

  @LUB-1004.1 @Integration
  Scenario: Preserve color components
    Given a protobuf color with opacity
    When the color is converted to a platform color and back
    Then its color components and opacity are preserved

  @LUB-1004.2 @Integration
  Scenario: Resolve missing Vision bounds
    Given a Vision region with missing bounds and a known input size
    When the effective region is resolved
    Then missing coordinates use zero and missing extents use the input dimensions
