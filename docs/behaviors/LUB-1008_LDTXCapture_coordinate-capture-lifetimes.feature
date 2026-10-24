# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1008 @LDTXCapture
Feature: LDTXCapture coordinate capture lifetimes

  @LUB-1008.1 @Unit
  Scenario: Serialize capture operations
    Given capture start and stop requests for one source
    When the requests are accepted
    Then capture operations execute in order

  @LUB-1008.2 @Integration
  Scenario: Recover from an unavailable camera
    Given a configured camera that is currently unavailable
    When capture synchronization runs and the camera later becomes available
    Then unavailability is reported and capture can subsequently start

  @LUB-1008.3 @Integration
  Scenario: Cancel obsolete reconnect work
    Given a camera with a pending reconnect
    When the camera is explicitly restarted or receives a valid frame
    Then the obsolete reconnect does not restart the active capture

