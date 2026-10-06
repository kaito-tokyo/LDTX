# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1010 @VideoComponentProgramLayers
Feature: Change canvas membership

  @UCT-1010.1
  Scenario: Component inspector membership uses latest program and preserves preferences
    Given component membership controls refer to Program IDs and saved preferences
    When membership changes across canvases, Program order changes, and referenced components disappear
    Then membership remains scoped to valid Programs and components, preserves preferences, and rejects changes during output

  @UCT-1010.2
  Scenario: Canvas membership and ordering remain local during output
    Given two Workspace Windows with video components
    When membership and ordering change across both canvases before and during output
    Then membership changes are rejected during output while reorder and supported preferences remain editable only in the owning Window
