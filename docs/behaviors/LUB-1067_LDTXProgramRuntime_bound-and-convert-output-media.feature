# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1067 @LDTXProgramRuntime
Feature: bound and convert output media

  @LUB-1067.1 @Integration
  Scenario: Isolate slow output subscribers
    Given multiple consumers of a shared ordered audio and video channel
    When one consumer stalls or exceeds its pending limit
    Then other consumers continue and the affected subscriber drains accepted events before closing

  @LUB-1067.2 @Unit
  Scenario: Preserve admitted media on overflow
    Given a bounded media backlog containing accepted samples
    When another video or audio sample exceeds capacity
    Then overflow is reported without discarding or reordering the accepted samples

  @LUB-1067.3 @Integration
  Scenario: Hold shared H264 memory until acknowledgement
    Given media payloads stored in shared slots
    When the service acknowledges a batch or a payload exceeds slot capacity
    Then acknowledged storage is released and oversized payloads are rejected

  @LUB-1067.4 @Integration
  Scenario: Preserve media format and high-resolution timestamps across IPC
    Given supported H264, AAC, or interleaved PCM samples
    When they are converted for the output process
    Then codec configuration, timestamps, and payload boundaries survive while malformed or unsupported formats fail
