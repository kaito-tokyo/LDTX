# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1011 @MasterVolumeEditor
Feature: Edit master volumes

  @UCT-1011.1
  Scenario: Master volume edits and model updates are reflected independently
    Given a Master Volume Editor for a selected Program
    When a master volume is submitted and then changed through the Workspace store
    Then the submitted gain persists and the field observes the later change

  @UCT-1011.2
  Scenario: Monitor volume remains local without marking the Workspace edited
    Given a Workspace with local monitor settings
    When the monitor volume changes
    Then local state updates without marking the Document edited
