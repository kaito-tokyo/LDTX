# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1019 @LDTXVideoComposition
Feature: LDTXVideoComposition describe composition inputs

  @LUB-1019.1 @Unit
  Scenario: Preserve component drawing values
    Given a composition component with geometry, color, and opacity
    When its drawing command is created
    Then the command preserves the configured drawing values

  @LUB-1019.2 @Integration
  Scenario: Keep source ownership and mask metadata
    Given a captured pixel buffer and an optional alpha mask
    When the source is passed into a composition
    Then the source retains its media backing and identifies the alpha mask format

