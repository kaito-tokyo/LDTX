// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import Testing

@testable import LDTXProgramRuntime

struct RecordingTimelineNormalizerTests {
  @Test func appliesOneCommonOriginAndKeepsRelativeStarts() throws {
    let normalizer = RecordingTimelineNormalizer(
      origin: CMTime(seconds: 100, preferredTimescale: 1_000)
    )
    let output = NormalizedSampleCollector()

    normalizer.submit(try sample(pts: 100.2), trackID: "video") { output.append("video", $0) }
    normalizer.submit(try sample(pts: 101.0), trackID: "side") { output.append("side", $0) }
    normalizer.submit(try sample(pts: 100.0), trackID: "main") { output.append("main", $0) }

    #expect(output.pts(for: "main") == 0)
    #expect(output.pts(for: "video") == 0.2)
    #expect(output.pts(for: "side") == 1.0)
  }

  @Test func doesNotWaitForOtherTracks() throws {
    let normalizer = RecordingTimelineNormalizer(
      origin: CMTime(seconds: 42, preferredTimescale: 1_000)
    )
    let output = NormalizedSampleCollector()
    normalizer.submit(try sample(pts: 42), trackID: "main") { output.append("main", $0) }
    #expect(output.pts(for: "main") == 0)
  }

  private func sample(pts: Double) throws -> CMSampleBuffer {
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 1_000),
      presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 1_000),
      decodeTimeStamp: CMTime(seconds: pts - 0.01, preferredTimescale: 1_000)
    )
    var sampleBuffer: CMSampleBuffer?
    let status = CMSampleBufferCreate(
      allocator: kCFAllocatorDefault,
      dataBuffer: nil,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: nil,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else { throw NormalizerTestError.sampleCreation }
    return sampleBuffer
  }
}

private final class NormalizedSampleCollector: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var values: [(String, CMSampleBuffer)] = []

  func append(_ trackID: String, _ sampleBuffer: CMSampleBuffer) {
    lock.withLock { values.append((trackID, sampleBuffer)) }
  }

  func pts(for trackID: String) -> Double? {
    lock.withLock {
      values.first(where: { $0.0 == trackID })?.1.presentationTimeStamp.seconds
    }
  }
}

private enum NormalizerTestError: Error {
  case sampleCreation
}
