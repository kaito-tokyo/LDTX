# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1030 @LDTXWorkspaceAppletController
Feature: LDTXWorkspaceAppletController connect documents to runtime

  @LUB-1030.1 @UIComponent
  Scenario: Retain runtime identity across view updates
    Given an open Workspace with a registered coordinator
    When the document content view is reconstructed
    Then the same coordinator remains connected

  @LUB-1030.2 @UIComponent
  Scenario: Scope document references to their owning views
    Given hosted views connected to different documents
    When a document URL changes or a document is released
    Then each view observes its own current URL without retaining its document
    And a view without a document remains usable

