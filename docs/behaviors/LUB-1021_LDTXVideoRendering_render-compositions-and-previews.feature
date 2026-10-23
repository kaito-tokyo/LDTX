# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1021 @LDTXVideoRendering
Feature: LDTXVideoRendering render compositions and previews

  @LUB-1021.1 @Integration
  Scenario: Composite visible content
    Given a supported composition with known colors and placement
    When a frame is rendered on Metal
    Then the rendered pixels reflect layer placement and opacity

  @LUB-1021.2 @Integration
  Scenario: Keep preview canvases distinct
    Given different Landscape and Portrait compositions
    When a paired preview is rendered
    Then each preview shows the corresponding canvas

  @LUB-1021.3 @Integration
  Scenario: Retain frames held by consumers
    Given a rendered frame retained by a consumer
    When additional frames are rendered
    Then the retained frame's pixels are not overwritten

