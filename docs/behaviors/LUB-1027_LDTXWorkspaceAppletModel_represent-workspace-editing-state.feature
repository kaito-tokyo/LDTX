# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1027 @LDTXWorkspaceAppletModel
Feature: LDTXWorkspaceAppletModel represent workspace editing state

  @LUB-1027.1 @Unit
  Scenario: Keep canvas editing targets distinct
    Given an editor targeting one canvas
    When the target is changed
    Then the target value identifies the selected canvas unambiguously

  @LUB-1027.2 @Unit
  Scenario: Capture reversible command values
    Given a Workspace edit with previous and replacement values
    When its transactional command is constructed
    Then the command retains the values needed to apply and reverse the edit

