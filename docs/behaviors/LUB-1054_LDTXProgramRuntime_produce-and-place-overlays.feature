# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1054 @LDTXProgramRuntime
Feature: produce and place overlays

  @LUB-1054.1 @Integration
  Scenario: Publish only the current overlay generation
    Given an overlay render in flight
    When configuration is replaced, deactivated, or removed
    Then obsolete work cannot publish and valid current work eventually replaces the texture

  @LUB-1054.2 @Integration
  Scenario: Retry a failed refresh without discarding the last texture
    Given an active overlay with a previous texture
    When a refresh fails and a valid retry becomes due
    Then the previous texture remains usable and a later successful retry replaces it without frame-driven retry loops

  @LUB-1054.3 @Integration
  Scenario: Coalesce changes and drain deactivation
    Given an overlay render held in flight with multiple pending updates
    When updates arrive and the producer is deactivated
    Then only the latest required update is retained and deactivation drains accepted rendering

  @LUB-1054.4 @Integration
  Scenario: Preserve text geometry and appearance
    Given Clock or rich Dynamic Text with font sizes, colors, outlines, and transforms
    When its texture and placement are generated
    Then glyph orientation, opacity, clipping, and scale match the authored content without shrinking text

  @LUB-1054.5 @Integration
  Scenario: Bound raster allocation and require usable font data
    Given an overlay requesting excessive pixels or an unavailable font
    When rendering is attempted
    Then it fails without excessive allocation or replacing a previously valid texture

  @LUB-1054.6 @Integration
  Scenario: Drive Clock from its own current-time source
    Given an active Clock with an injected time zone and current-time provider
    When timer updates occur while frame timestamps vary
    Then displayed time follows that provider and timers stop on deactivation or release
