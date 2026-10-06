# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1020 @RecordPlayerDocument
Feature: Persist marker edits

  @UCT-1020.1
  Scenario: Marker additions await Save and deletion is immediate
    Given a recording has no saved markers
    When a marker is added, saved, and deleted
    Then addition remains pending until Save and deletion immediately updates disk without resetting playback

  @UCT-1020.2
  Scenario: Observers follow marker edits and disk synchronization
    Given a recording marker list is observed
    When markers are added, synchronized with disk, and deleted
    Then each list change is observable and disk-only markers are included after saving

  @UCT-1020.3
  Scenario: Canonical collisions preserve filenames and pending edits
    Given a recording has a marker with an equivalent canonical timestamp
    When a replacement is saved and then deleted while another marker remains pending
    Then the existing filename is reused and deletion does not discard the other pending marker

  @UCT-1020.4
  Scenario: A failed reread retains edits for retry
    Given a recording has a pending marker and an unreadable disk-only marker
    When saving fails and the unreadable marker is repaired before retrying
    Then pending edits are retained and successful retry includes the repaired disk-only marker

  @UCT-1020.5
  Scenario: A failed deletion retains a clean marker list
    Given a saved marker file has been replaced by a directory
    When the user attempts to delete the marker
    Then deletion reports failure while the marker remains and the Document stays clean

  @UCT-1020.6
  Scenario: Hosted panes observe only their own recording markers
    Given two panes refer to one recording and a third refers to another
    When markers in the first recording are added, saved, and deleted
    Then both associated panes update while the other recording pane remains unchanged

  @UCT-1020.7
  Scenario: Failed save and revert preserve pending markers
    Given a recording has pending markers and an active-recording shield
    When saving and reverting to an invalid URL are attempted
    Then pending markers and edited state remain and unsupported document actions are unavailable
