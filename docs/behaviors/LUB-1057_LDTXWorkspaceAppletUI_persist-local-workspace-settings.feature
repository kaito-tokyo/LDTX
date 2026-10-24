# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1057 @LDTXWorkspaceAppletUI
Feature: persist local workspace settings

  @LUB-1057.1 @Integration
  Scenario: Persist only saved document state
    Given transient local state for an unsaved Workspace
    When the Workspace is saved to a package URL
    Then local state becomes restorable for that saved package without prematurely persisting the transient identity

  @LUB-1057.2 @Integration
  Scenario: Key output assignments by external Workspace identity
    Given a saved Workspace with output assignments and window-local state
    When the Workspace moves or its local settings are reloaded
    Then output assignments follow its external identity while window-local settings retain their own scope

  @LUB-1057.3 @Integration
  Scenario: Migrate old settings without replaying migration
    Given old local settings and current persisted values
    When settings are loaded and later explicitly cleared or changed
    Then supported values migrate once and obsolete formats cannot overwrite newer choices
