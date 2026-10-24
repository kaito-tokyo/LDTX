# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1052 @LDTXProgramRuntime
Feature: update programs without restarting inputs

  @LUB-1052.1 @Integration
  Scenario: Share current Program and preference values
    Given Program runtimes sharing a preference state
    When the current definition or live preferences change
    Then consumers observe the new values while equal updates do not publish a new revision

  @LUB-1052.2 @Integration
  Scenario: Apply placement independently of input pipelines
    Given a running Program with a prepared input pipeline and retained overlays
    When only layer placement or visibility changes
    Then composition updates without replacing the input pipeline or capture timing state

  @LUB-1052.3 @Integration
  Scenario: Keep output running across Program switches
    Given an active recording and another valid Program
    When the selected Program changes
    Then new frames use the selected Program while the same recording package remains active

  @LUB-1052.4 @Integration
  Scenario: Use explicit valid Program selection
    Given a Workspace with selected and unselected Programs
    When a Program is selected or removed
    Then the selected runtime follows a valid remaining Program without inventing a missing definition
