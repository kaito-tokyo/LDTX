# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1002 @LDTXWorkspaceBundleFormat
Feature: LDTXWorkspaceBundleFormat validate and persist workspaces

  @LUB-1002.1 @Integration
  Scenario: Round trip a valid V4 bundle
    Given a valid Workspace with bundled resources
    When the bundle is written and read
    Then the Workspace values and referenced resources are restored

  @LUB-1002.2 @Unit
  Scenario: Report invalid content
    Given a Workspace with invalid references or rational denominators
    When the Workspace is validated
    Then validation reports the invalid content instead of silently repairing it

  @LUB-1002.3 @Integration
  Scenario: Keep reading separate from writing
    Given an older valid V4 bundle with preserved unknown data
    When the bundle is read
    Then its files are not rewritten and the unknown data remains available

