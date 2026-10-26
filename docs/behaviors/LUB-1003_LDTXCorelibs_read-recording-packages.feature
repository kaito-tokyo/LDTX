# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1003 @LDTXCorelibs
Feature: LDTXCorelibs read recording packages

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

  @LUB-1003.3 @Integration
  Scenario: Reject paths escaping a recording package
    Given metadata containing an unsafe relative path or a package containing symbolic links
    When the package is opened
    Then unsafe references and symbolic links are rejected without accessing media outside the package

  @LUB-1003.4 @Integration
  Scenario: Resolve media according to the recording format
    Given a supported legacy or dual-canvas recording package
    When its selected canvas and audio tracks are resolved
    Then media references follow that format without requiring an unselected canvas file
    And unsupported format versions and reserved track identifiers are rejected

  @LUB-1003.5 @Integration
  Scenario: Distinguish an active package from a finalized recording
    Given a readable package whose manifest or finalized marker is not yet present
    When package metadata is read and finalized output is explicitly required
    Then metadata remains readable but the finalized requirement fails until the marker exists

