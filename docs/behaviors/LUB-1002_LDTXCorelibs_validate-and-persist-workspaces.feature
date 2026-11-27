# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1002 @LDTXCorelibs
Feature: LDTXCorelibs validate and persist workspaces

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

  @LUB-1002.4 @Unit
  Scenario: Collect independent validation issues
    Given a Workspace containing invalid Clock geometry and colors
    When the Workspace is validated
    Then each issue is reported with its field path and owning entity


  @LUB-1002.5 @Integration
  Scenario: Write a complete package from the Workspace alone
    Given a Workspace whose models were read from another package
    When the Workspace is written to a new destination and its sources are removed
    Then the destination holds the metadata, documents, and models without reading anything else

  @LUB-1002.6 @Unit
  Scenario: Keep model copies outside the package
    Given a model chosen for an ID
    When it is staged into a model cache and the chosen file later changes or disappears
    Then the first copy for that ID is reused unchanged
