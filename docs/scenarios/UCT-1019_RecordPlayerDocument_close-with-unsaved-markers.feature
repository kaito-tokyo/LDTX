# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1019 @RecordPlayerDocument
Feature: Close with unsaved markers

  @UCT-1019.1
  Scenario: Closing a clean recording stops playback
    Given a clean recording is open and playing
    When the user closes its window
    Then playback stops and the Document is unregistered

  @UCT-1019.2
  Scenario: Cancel preserves playback and Discard stops it
    Given a playing recording has an unsaved marker
    When the user cancels closure and then closes with Discard
    Then Cancel retains playback and edits while Discard closes without saving the marker

  @UCT-1019.3
  Scenario: Save on close persists markers before allowing closure
    Given a playing recording has an unsaved marker
    When the user selects Save in the close confirmation
    Then the marker is saved before closure is allowed and playback stops when the Document closes

  @UCT-1019.4
  Scenario: Closing cancels pending asset loading
    Given a recording is waiting for its asset loader
    When the Document closes before the asset loader completes
    Then the later loader result does not restart playback

  @UCT-1019.5
  Scenario: Retained UI and model do not keep the Document alive
    Given a recording model and pane remain referenced after closure
    When the Document owner is released and the retained model tries to start
    Then the Document is released and no new asset load begins
