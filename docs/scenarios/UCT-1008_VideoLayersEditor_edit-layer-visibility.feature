# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1008 @VideoLayersEditor
Feature: Edit layer visibility

  @UCT-1008.1
  Scenario: Hide callbacks restore state on failure
    Given a layer visibility control has a successful callback followed by a failing one
    When the user toggles visibility through both callbacks
    Then successful changes are forwarded and failure restores state while reporting the error
