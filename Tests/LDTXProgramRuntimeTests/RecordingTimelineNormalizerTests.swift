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
    let window = SessionRecordInputWindow()
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

  @Test func recordInputWindowDropsLateSamplesBeforeTheActivatedOrigin() throws {
    let window = SessionRecordInputWindow()
    let output = NormalizedSampleCollector()

    window.activate(at: CMTime(seconds: 100, preferredTimescale: 1_000))
    window.submit(try sample(pts: 99.9)) { output.append("late", $0) }
    window.submit(try sample(pts: 100.1)) { output.append("accepted", $0) }

    #expect(output.pts(for: "late") == nil)
    #expect(output.pts(for: "accepted") == 100.1)
  }

  @Test func recordInputWindowKeepsOneSixtySecondWindowAcrossTracks() throws {
    let window = SessionRecordInputWindow()
    let output = NormalizedSampleCollector()

    window.submit(try sample(pts: 0)) { output.append("old-track-a", $0) }
    window.submit(try sample(pts: 30)) { output.append("kept-track-b", $0) }
    window.submit(try sample(pts: 61)) { output.append("latest-track-a", $0) }
    window.activate(at: .zero)

    #expect(output.pts(for: "old-track-a") == nil)
    #expect(output.pts(for: "kept-track-b") == 30)
    #expect(output.pts(for: "latest-track-a") == 61)
  }

  @Test func recordInputWindowDoesNotMoveSixtySecondWindowBackwardForLateSamples() throws {
    let window = SessionRecordInputWindow()
    let output = NormalizedSampleCollector()

    window.submit(try sample(pts: 100)) { output.append("latest", $0) }
    window.submit(try sample(pts: 39)) { output.append("late-old", $0) }
    window.submit(try sample(pts: 40)) { output.append("boundary", $0) }
    window.activate(at: .zero)

    #expect(output.pts(for: "latest") == 100)
    #expect(output.pts(for: "late-old") == nil)
    #expect(output.pts(for: "boundary") == 40)
  }

  @Test func pendingAudioWindowUsesOnePTSWindowAndPreservesCrossTrackArrivalOrder() throws {
    let window = SessionRecordPendingAudioWindow()
    window.append(.input(try sample(pts: 0), trackID: "old"))
    window.append(.main(try sample(pts: 30)))
    window.append(.input(try sample(pts: 60), trackID: "input-a"))
    window.append(.main(try sample(pts: 61)))

    let drained = window.drain(startingAt: CMTime(seconds: 20, preferredTimescale: 1_000))
    #expect(drained.count == 3)
    guard drained.count == 3 else { return }
    if case .main(let first) = drained[0] {
      #expect(first.presentationTimeStamp.seconds == 30)
    } else {
      Issue.record("Expected Main Mix to retain its arrival position")
    }
    if case .input(let second, let trackID) = drained[1] {
      #expect(trackID == "input-a")
      #expect(second.presentationTimeStamp.seconds == 60)
    } else {
      Issue.record("Expected input audio to retain its arrival position")
    }
    if case .main(let third) = drained[2] {
      #expect(third.presentationTimeStamp.seconds == 61)
    } else {
      Issue.record("Expected the latest Main Mix sample")
    }
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
