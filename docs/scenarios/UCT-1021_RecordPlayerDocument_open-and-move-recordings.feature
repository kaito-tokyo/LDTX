# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1021 @RecordPlayerDocument
Feature: Open and move recordings

  @UCT-1021.1
  Scenario: Malformed optional markers do not block the player
    Given a recording contains an unreadable optional marker
    When the player opens and saving or reverting is attempted before and after repair
    Then the player model is available while unreadable markers cannot be overwritten and repair permits retry

  @UCT-1021.2
  Scenario: The registered recording alias supports opening and saving
    Given a recording package uses the existing registered type alias
    When a marker is added and saved through that type
    Then the marker persists and the Document becomes clean

  @UCT-1021.3
  Scenario: Recording Documents coexist with Workspace Documents
    Given a Workspace is registered with the shared Document Controller
    When the same recording package is opened twice
    Then one recording Document is reused and both document families remain registered

  @UCT-1021.4
  Scenario: A moved recording preserves markers and loads its current URL
    Given a recording has saved and pending markers with a loaded player
    When the package moves and the canvas is changed before saving
    Then loading uses the new URL and saving preserves all markers while a later save failure retains new edits

  @UCT-1021.5
  Scenario: The shared controller resolves both Document families
    Given the shared component-test Document Controller is initialized
    When Workspace, recording, and recording-alias types and URLs are resolved
    Then the controller is the standard shared instance and resolves each to its owning Document class
