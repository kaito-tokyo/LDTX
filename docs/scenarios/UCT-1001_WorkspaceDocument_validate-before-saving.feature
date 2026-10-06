# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1001 @WorkspaceDocument
Feature: Validate Workspace contents before saving

  @UCT-1001.1 @WorkspaceStoreService
  Scenario: Validation aggregates problems before creating a package
    Given a new Workspace has invalid names and transforms
    When the user saves the Workspace
    Then one validation error contains all problems and no package is created

  @UCT-1001.2 @WorkspaceStoreService
  Scenario: A corrected Workspace saves retained detached preferences
    Given a saved Workspace has an invalid transform
    When saving fails and the transform is corrected before retrying
    Then the failed save preserves existing files and the retry preserves detached layer preferences

  @UCT-1001.3 @WorkspaceStoreService
  Scenario: The Save action presents one aggregated validation sheet
    Given an open Workspace has invalid Landscape and Portrait preferences
    When the user invokes Save
    Then one error sheet describes both invalid preferences

  @UCT-1001.4 @WorkspaceStoreService
  Scenario: Background save validates its captured snapshot before writing
    Given a background save has captured invalid audio preferences
    When the live preferences are corrected and the captured snapshot is written
    Then the captured snapshot fails validation without creating a package
