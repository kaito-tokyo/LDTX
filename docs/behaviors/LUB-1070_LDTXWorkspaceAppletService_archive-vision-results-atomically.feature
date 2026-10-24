# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1070 @LDTXWorkspaceAppletService
Feature: archive vision results atomically

  @LUB-1070.1 @Integration
  Scenario: Commit matching image and metadata together
    Given a Vision result destined for a recording package
    When the archive write succeeds or fails partway through
    Then success creates a readable pair and failure removes partial new files while preserving existing collisions

  @LUB-1070.2 @Integration
  Scenario: Preserve the original archive error
    Given an archive write and its rollback both fail
    When the result is reported
    Then the original write failure remains primary

  @LUB-1070.3 @Integration
  Scenario: Drain only the owning recording's archives
    Given accepted Vision archive work in two Workspaces
    When one recording pauses or stops
    Then its finalization waits for its own accepted archive work without waiting for the other Workspace
