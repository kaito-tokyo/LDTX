# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1055 @LDTXProgramRuntime
Feature: share and fence audio delivery

  @LUB-1055.1 @Integration
  Scenario: Share physical capture across logical consumers
    Given multiple logical routes using one physical audio device
    When consumers subscribe, unsubscribe, or change monitor routing and gains
    Then capture remains shared and monitor changes do not restart the input generation

  @LUB-1055.2 @Integration
  Scenario: Fence callbacks on unsubscribe and stop
    Given an audio callback copied for delivery or already in flight
    When unsubscribe or shutdown completes
    Then no later callback reaches the retired subscriber and repeated cancellation joins the same fence

  @LUB-1055.3 @Integration
  Scenario: Recover from failed capture without stale delivery
    Given capture fails during start or runtime
    When all affected subscribers complete and a later subscription retries
    Then failure is reported once per subscriber and callbacks from the retired capture cannot contaminate its replacement

  @LUB-1055.4 @Integration
  Scenario: Produce bounded clocked audio
    Given a monitor mixer with missing or late input
    When its output clock advances
    Then missing frames become silence and catch-up work remains bounded
