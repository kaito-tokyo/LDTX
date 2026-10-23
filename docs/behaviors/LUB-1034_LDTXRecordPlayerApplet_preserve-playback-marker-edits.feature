# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1034 @LDTXRecordPlayerApplet
Feature: LDTXRecordPlayerApplet preserve playback marker edits

  @LUB-1034.1 @UIComponent
  Scenario: Persist edited markers
    Given an open recording with marker edits
    When the recording document is saved and reopened
    Then the edited markers are restored

  @LUB-1034.2 @UIComponent
  Scenario: Cancel closing with unsaved markers
    Given a recording document with unsaved marker changes
    When closing is cancelled in the confirmation sheet
    Then the document stays open with its edits intact

