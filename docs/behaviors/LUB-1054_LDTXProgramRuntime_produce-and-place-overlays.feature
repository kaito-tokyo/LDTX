# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1054 @LDTXProgramRuntime
Feature: produce and place overlays

  @LUB-1054.1 @Integration
  Scenario Outline: Reject obsolete overlay publication
    Given an overlay render in flight
    When its producer is <change>
    Then that render cannot publish into the current generation

    Examples:
      | change      |
      | reconfigured |
      | deactivated |
      | reactivated |

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
  Scenario Outline: Reject excessive Dynamic Text raster dimensions
    Given Dynamic Text with width <width> and height <height>
    When its overlay is rendered
    Then rendering <result>

    Examples:
      | width | height | result                         |
      | 16384 | 16384  | fails before raster allocation |
      | 4096  | 2049   | fails before raster allocation |
      | 4096  | 2048   | creates the requested texture  |

  @LUB-1054.6 @Integration
  Scenario: Drive Clock from its own current-time source
    Given an active Clock with an injected time zone and current-time provider
    When timer updates occur while frame timestamps vary
    Then displayed time follows that provider and timers stop on deactivation or release

  @LUB-1054.7 @Integration
  Scenario: Report unavailable font data
    Given an overlay renderer with a missing font resource
    When the renderer is constructed
    Then construction reports unavailable font data
