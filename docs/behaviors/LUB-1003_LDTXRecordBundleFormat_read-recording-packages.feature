# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1003 @LDTXRecordBundleFormat
Feature: LDTXRecordBundleFormat read recording packages

  @LUB-1003.1 @Integration
  Scenario: Restore recording metadata
    Given a recording package with metadata, markers, and media references
    When the package is read
    Then the saved values and media locations are restored

  @LUB-1003.2 @Unit
  Scenario: Interpret DASH segment timing
    Given a DASH manifest with segment timing entries
    When its recording timeline is parsed
    Then segment times and durations retain their declared timescale

