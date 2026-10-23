# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1027 @LDTXWorkspaceAppletModel
Feature: Restrict Workspace commands and report their failures

  @LUB-1027.1 @Unit
  Scenario: Restrict commands during output
    Given a Workspace with active output
    When a transactional command is checked for admission
    Then Program switching and Stop are allowed
    And runtime reconstruction, device reassignment, another Start, and Close are disallowed

  @LUB-1027.2 @Unit
  Scenario: Preserve actionable failure guidance
    Given failed Workspace commands including Stop and Close and an underlying error
    When their failures are combined for presentation
    Then every failed command and the underlying cause remain visible
    And Stop is not reported as successful
    And Close guidance explains the potential loss from Force Quit without performing it

