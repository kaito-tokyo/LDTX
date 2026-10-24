# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1056 @LDTXRecording
Feature: edit and persist recording markers

  @LUB-1056.1 @Integration
  Scenario: Save only marker changes
    Given an existing recording containing media, markers, and unrelated files
    When markers are edited, saved, or deleted
    Then the intended marker changes persist without altering media or unrelated markers

  @LUB-1056.2 @Integration
  Scenario: Validate and order marker timestamps
    Given marker input with duplicate, invalid, or subprecision timestamps
    When markers are created and listed
    Then invalid or duplicate times are rejected and accepted times are rounded and listed in playback order

  @LUB-1056.3 @Integration
  Scenario: Retry a failed marker save safely
    Given a partial marker write or deletion that fails
    When saving is retried
    Then pending edits remain available and already completed deletions are not repeated against unrelated files

  @LUB-1056.4 @UIComponent
  Scenario: Keep document lifetime and Undo independent of playback views
    Given a recording document with unsaved marker edits and a playback view
    When views rebuild, Undo or Redo executes, or close is cancelled
    Then the document retains its edits and playback identity until accepted closure releases playback

  @LUB-1056.5 @UIComponent
  Scenario: Open or move a recording document
    Given a recording package with valid or malformed marker data
    When the document opens or moves to another location
    Then valid package content remains available and failures retain their details without silently repairing invalid markers
