# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1014 @AudioPeakMeter
Feature: Display audio peaks with SwiftUI

  @UCT-1014.1
  Scenario: Peak attack is immediate and release follows elapsed time
    Given a silent meter
    When a full-scale peak arrives followed by silence for 1.7 seconds
    Then the peak immediately reaches zero decibels and releases by twenty decibels
