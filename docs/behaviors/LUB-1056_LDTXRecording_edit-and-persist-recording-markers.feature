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

  @LUB-1056.6 @UIComponent
  Scenario: Stop playback when its document is released
    Given a recording document with a retained playback model
    When the document is released
    Then playback stops even if the model remains referenced

  @LUB-1056.7 @UIComponent
  Scenario: Preserve the original marker filename for a canonical collision
    Given a recording with a marker whose timestamp has an equivalent canonical representation
    When the marker is replaced and saved
    Then its existing filename is reused for the replacement

  @LUB-1056.8 @UIComponent
  Scenario: Retain a failed marker deletion for Undo
    Given a saved marker whose file cannot be deleted
    When the marker is removed and saving fails
    Then the deletion remains pending and Undo can restore the marker in memory

  @LUB-1056.9 @UIComponent
  Scenario: Protect unreadable markers while allowing playback
    Given a recording containing an unreadable optional marker
    When the document opens and a marker edit is saved
    Then the player remains available and the unreadable marker is not overwritten
    And the failed save retains the pending edit

  @LUB-1056.10 @UIComponent
  Scenario: Load playback from the current recording location
    Given a recording document whose package has moved
    When its reader applies a snapshot from the new location and playback starts
    Then playback loads the recording from the new location

  @LUB-1056.11 @UIComponent
  Scenario: Ignore an asset load completed after playback stops
    Given a recording player waiting for an asset to load
    When playback stops before loading completes
    Then the pending load is cancelled and its late result cannot restart playback

  @LUB-1056.12 @UIComponent
  Scenario: Preserve pending markers when a reread fails
    Given an open recording with pending marker edits
    When a new reader snapshot reports an unreadable marker
    Then applying that snapshot fails and the pending marker edits remain available

  @LUB-1056.13 @UIComponent
  Scenario: Show the markers of the owning recording
    Given playback views associated with different recording documents
    When markers are edited or a reader snapshot is applied to one document
    Then views of that document show its current markers
    And views of other recording documents remain unchanged
