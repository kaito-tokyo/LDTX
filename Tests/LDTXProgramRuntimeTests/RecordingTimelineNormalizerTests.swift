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

  @Test func unactivatedTimelineDropsSamplesAndFirstActivationDefinesZero() throws {
    let normalizer = RecordingTimelineNormalizer()
    let output = NormalizedSampleCollector()

    normalizer.submit(try sample(pts: 49.9), trackID: "raw") {
      output.append("before", $0)
    }
    #expect(output.pts(for: "before") == nil)

    #expect(normalizer.activate(at: CMTime(seconds: 50, preferredTimescale: 1_000)) != nil)
    normalizer.submit(try sample(pts: 50.25), trackID: "raw") {
      output.append("after", $0)
    }
    #expect(output.pts(for: "after") == 0.25)

    normalizer.finish()
    normalizer.submit(try sample(pts: 51), trackID: "raw") {
      output.append("finished", $0)
    }
    #expect(output.pts(for: "finished") == nil)
  }

  @Test func recordInputWindowBuffersUntilOutputStartAndStopsAtOutputBoundary() throws {
    let window = ProgramRecordInputRecordingWindow()
    let start = CMTime(seconds: 100, preferredTimescale: 48_000)
    let output = NormalizedSampleCollector()

    window.submit(try sample(pts: 99.9)) { output.append("before", $0) }
    window.submit(try sample(pts: 100.1)) { output.append("buffered", $0) }
    #expect(output.pts(for: "before") == nil)
    #expect(output.pts(for: "buffered") == nil)

    window.activate(at: start)
    #expect(output.pts(for: "before") == nil)
    #expect(output.pts(for: "buffered") == 100.1)

    window.submit(try sample(pts: 100.2)) { output.append("live", $0) }
    #expect(output.pts(for: "live") == 100.2)

    window.seal()
    window.submit(try sample(pts: 100.3)) { output.append("sealed", $0) }
    #expect(output.pts(for: "sealed") == nil)
  }

  @Test func recordInputWindowHoldsCutSamplesAndSealsBeforeBoundary() throws {
    let window = ProgramRecordInputRecordingWindow()
    let output = NormalizedSampleCollector()
    window.activate(at: CMTime(seconds: 100, preferredTimescale: 48_000))

    window.submit(try sample(pts: 100.1)) { output.append("live", $0) }
    window.prepareCut()
    window.submit(try sample(pts: 101.9)) { output.append("before-cut", $0) }
    window.submit(try sample(pts: 102.0)) { output.append("at-cut", $0) }
    window.submit(try sample(pts: 102.1)) { output.append("after-cut", $0) }

    #expect(output.pts(for: "live") == 100.1)
    #expect(output.pts(for: "before-cut") == nil)
    window.seal(before: CMTime(seconds: 102, preferredTimescale: 48_000))
    #expect(output.pts(for: "before-cut") == 101.9)
    #expect(output.pts(for: "at-cut") == nil)
    #expect(output.pts(for: "after-cut") == nil)
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
