// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

@testable import LDTXWorkspaceAppletUI
import Testing

@Suite("Audio peak envelope", .tags(.easy))
struct AudioPeakEnvelopeUnitTestSuite {
  @Test("LUB-1068: Attack release and clamping") func attackReleaseAndClamping() {
    var envelope = AudioPeakEnvelope()
    envelope.update(peak: 1, elapsed: 0)
    #expect(envelope.level == 1)
    envelope.update(peak: 0, elapsed: 1.7)
    #expect(abs(envelope.decibels + 20) < 0.001)
    envelope.update(peak: 0, elapsed: 10)
    #expect(envelope.level == 0)
    envelope.update(peak: 10, elapsed: 0)
    #expect(envelope.level == 1)
    envelope.update(peak: .nan, elapsed: 10)
    #expect(envelope.level == 0)
  }
}
