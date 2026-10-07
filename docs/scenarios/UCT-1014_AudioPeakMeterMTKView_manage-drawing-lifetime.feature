# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1014 @AudioPeakMeterMTKView
Feature: Manage drawing lifetime

  @UCT-1014.1
  Scenario: Drawing follows Window attachment and UI releases without external stop calls
    Given a meter and editors whose owning references can be released
    When the meter attaches, its Window closes, it reconnects, and UI owners are released
    Then drawing pauses on closure or detachment, resumes on reconnection, and the UI is released without external stop calls
