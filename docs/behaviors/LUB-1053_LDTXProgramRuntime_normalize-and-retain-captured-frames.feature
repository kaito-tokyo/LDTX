# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1053 @LDTXProgramRuntime
Feature: normalize and retain captured frames

  @LUB-1053.1 @Integration
  Scenario: Normalize supported camera formats numerically
    Given NV12 or BGRA input with declared range, matrix, transfer function, and geometry
    When the input is normalized for rendering
    Then pixels are converted to the canonical output colors and dimensions while source buffers remain unchanged

  @LUB-1053.2 @Integration
  Scenario: Recover from unsupported input
    Given one camera produces unsupported metadata or a conversion failure
    When other sources render and a later valid camera frame arrives
    Then unrelated content continues rendering and the camera can recover

  @LUB-1053.3 @Integration
  Scenario: Keep retained output immutable
    Given a consumer holding a previously normalized or rendered frame
    When more frames are produced
    Then the held pixels and source metadata remain unchanged until released

  @LUB-1053.4 @Integration
  Scenario: Use explicit preprocessing and foreground masks
    Given a camera frame and an optional background-removal implementation
    When the preprocessing pipeline runs
    Then the provider receives the original frame and the resulting mask is applied with its declared format
