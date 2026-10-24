# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1072 @LDTXWorkspaceAppletService
Feature: Project saved settings into runtime values

  @LUB-1072.1 @Unit
  Scenario: Preserve independent canvas geometry
    Given saved Landscape and Portrait definitions, transforms, visibility, and bit rates
    When runtime canvas snapshots and render graphs are built
    Then each canvas receives its own saved settings and absent scale remains distinct from explicit zero
    And Clock font size remains in Landscape pixels before layer scaling

  @LUB-1072.2 @Unit
  Scenario: Derive audio routing independently of Program membership
    Given Workspace audio inputs, live channel gains, and a local monitor volume
    When monitor and output routing values are projected
    Then monitor routes can exist without a selected Program
    And monitor and output master levels retain their own scope

