# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1062 @LDTXWorkspaceAppletService
Feature: recover youtube output from checkpoints

  @LUB-1062.1 @Integration
  Scenario: Resume from the last matching checkpoint
    Given an interrupted output with a committed matching configuration checkpoint
    When a replacement service process starts
    Then segment numbering and media time resume from that checkpoint while stale revisions are rejected

  @LUB-1062.2 @Integration
  Scenario: Bound retries and cancel them on Stop
    Given a service process repeatedly failing during startup or recovery
    When retry delays elapse or Stop is requested
    Then retries stop at the configured budget and Stop prevents replacement sessions

  @LUB-1062.3 @Integration
  Scenario: Require committed delivery before declaring recovery
    Given a replacement session still priming
    When media checkpoints arrive or delivery times out
    Then only the current revision's committed delivery restores recovery and the watchdog does not silently reset across replacements

  @LUB-1062.4 @Integration
  Scenario: Preserve finalization failures
    Given an output client waiting for final media acknowledgements or service finish
    When finish fails or times out
    Then the caller receives failure and accepted storage remains owned until the connection boundary is safely released

  @LUB-1062.5 @Unit
  Scenario: Keep continuity scoped to endpoint and configuration
    Given saved in-memory stream continuity for multiple endpoints
    When a checkpoint with matching or different fingerprint arrives
    Then only matching endpoint and configuration state advances and transient checkpoints are not persisted as document content
