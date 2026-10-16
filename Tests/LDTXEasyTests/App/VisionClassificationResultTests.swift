// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXVision
import Testing

@Suite struct VisionClassificationResultUnitTestSuite {
  @Test func choosesHighestConfidenceAndPreservesFirstTie() {
    let result = VisionClassificationResult(candidates: [
      .init(label: "low", confidence: 0.1),
      .init(label: "first", confidence: 0.8),
      .init(label: "second", confidence: 0.8),
    ])
    #expect(result.topCandidate?.label == "first")
    #expect(result.topCandidate?.confidence == 0.8)
    #expect(result.displayText == "low: 10.0%\nfirst: 80.0%\nsecond: 80.0%")
    #expect(VisionClassificationResult(candidates: []).topCandidate == nil)
    #expect(VisionClassificationResult(candidates: []).displayText == "")
  }
}
