// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

public struct YouTubeOutputSequenceGate: Sendable {
  public private(set) var context: YouTubeOutputContext
  public private(set) var expectedSequence: UInt64

  public init(context: YouTubeOutputContext, expectedSequence: UInt64 = 0) {
    self.context = context
    self.expectedSequence = expectedSequence
  }

  public mutating func accept(_ batch: YouTubeOutputMediaBatch) throws {
    guard batch.protocolVersion == LDTXYouTubeOutputServiceInterfaces.protocolVersion else {
      throw YouTubeOutputSequenceError.unsupportedProtocolVersion(batch.protocolVersion)
    }
    guard batch.context == context else {
      throw YouTubeOutputSequenceError.staleContext
    }
    guard batch.sequence == expectedSequence else {
      throw YouTubeOutputSequenceError.unexpectedSequence(
        expected: expectedSequence, actual: batch.sequence)
    }
    expectedSequence += 1
  }
}

public enum YouTubeOutputSequenceError: Error, Equatable, Sendable {
  case unsupportedProtocolVersion(UInt32)
  case staleContext
  case unexpectedSequence(expected: UInt64, actual: UInt64)
}
