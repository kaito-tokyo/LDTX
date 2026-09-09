// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Testing

@testable import LDTXMP4

@Suite(.serialized)
struct H264VideoEncoderHardTests {
  @Test func testAssetWriterLifecycleGateHoldsStartsUntilFinishCompletes() {
    let finishEntered = DispatchSemaphore(value: 0)
    let releaseFinish = DispatchSemaphore(value: 0)
    let finishCompleted = DispatchSemaphore(value: 0)
    let startEntered = DispatchSemaphore(value: 0)

    AVAssetWriterLifecycleGate.finish(
      { completion in
        finishEntered.signal()
        DispatchQueue.global().async {
          releaseFinish.wait()
          completion()
        }
      },
      completion: { finishCompleted.signal() })
    assertEqual(finishEntered.wait(timeout: .now() + 1), .success)

    DispatchQueue.global().async {
      AVAssetWriterLifecycleGate.start { startEntered.signal() }
    }
    assertEqual(startEntered.wait(timeout: .now() + 0.05), .timedOut)

    releaseFinish.signal()
    assertEqual(finishCompleted.wait(timeout: .now() + 1), .success)
    assertEqual(startEntered.wait(timeout: .now() + 1), .success)
  }

  @Test func testMuxedSegmentTimingIgnoresEmptyTrackAtZero() throws {
    let timing = try unwrap(
      MuxedPassthroughSegmentedMP4Writer.segmentTiming(
        trackTimings: [
          MuxedPassthroughTrackTiming(
            earliestPresentationTimeSeconds: 0, durationSeconds: 0),
          MuxedPassthroughTrackTiming(
            earliestPresentationTimeSeconds: 2_170.915, durationSeconds: 0.002),
        ]))

    assertEqual(timing.earliestPresentationTimeSeconds, 2_170.915)
    assertEqual(timing.durationSeconds, 0.002)
  }

  @Test func testMuxedSegmentTimingRejectsTracksWithoutEffectiveMedia() {
    assertNil(
      MuxedPassthroughSegmentedMP4Writer.segmentTiming(
        trackTimings: [
          MuxedPassthroughTrackTiming(
            earliestPresentationTimeSeconds: 0, durationSeconds: 0),
          MuxedPassthroughTrackTiming(
            earliestPresentationTimeSeconds: .nan, durationSeconds: 1),
        ]))
  }

  @Test func testMuxedWriterOmitsOnlyExplicitlyEmptyTrackReports() {
    assertTrue(
      MuxedPassthroughSegmentedMP4Writer.containsOnlyEmptyTracks([
        MuxedPassthroughTrackTiming(
          earliestPresentationTimeSeconds: 0, durationSeconds: 0)
      ]))
    assertFalse(MuxedPassthroughSegmentedMP4Writer.containsOnlyEmptyTracks([]))
    assertFalse(
      MuxedPassthroughSegmentedMP4Writer.containsOnlyEmptyTracks([
        MuxedPassthroughTrackTiming(
          earliestPresentationTimeSeconds: .nan, durationSeconds: .nan)
      ]))
    assertFalse(
      MuxedPassthroughSegmentedMP4Writer.containsOnlyEmptyTracks([
        MuxedPassthroughTrackTiming(
          earliestPresentationTimeSeconds: 2_170.915, durationSeconds: 0.002)
      ]))
  }

  @Test func testPassthroughPendingSampleLimitAllowsItsBoundaries() {
    assertFalse(
      H264PassthroughPendingSampleLimit.isExceeded(
        count: 10_000,
        earliestPresentationTime: .zero,
        latestPresentationTime: CMTime(seconds: 30, preferredTimescale: 600)))
  }

  @Test func testPassthroughPendingSampleLimitRejectsExcessCountAndDuration() {
    assertTrue(
      H264PassthroughPendingSampleLimit.isExceeded(
        count: 10_001,
        earliestPresentationTime: .zero,
        latestPresentationTime: .zero))
    assertTrue(
      H264PassthroughPendingSampleLimit.isExceeded(
        count: 1,
        earliestPresentationTime: .zero,
        latestPresentationTime: CMTime(seconds: 30.001, preferredTimescale: 1_000)))
  }

  @Test func testHigh42CodecValidationAllowsConstraintFlags() {
    assertTrue(H264VideoEncoder.isHigh42CodecString("avc1.64002a"))
    assertTrue(H264VideoEncoder.isHigh42CodecString("avc1.640c2a"))
    assertFalse(H264VideoEncoder.isHigh42CodecString("avc1.4d002a"))
    assertFalse(H264VideoEncoder.isHigh42CodecString("avc1.640029"))
    assertFalse(H264VideoEncoder.isHigh42CodecString("avc1.invalid"))
  }

  @Test func testEncoderAcceptsCanonicalFullRangeNV12Input() async throws {
    let output = H264EncoderOutput()
    let encoder = try H264VideoEncoder(
      configuration: H264VideoEncoderConfiguration(
        width: 320, height: 180, frameRate: 30, bitRate: 800_000)
    ) { output.append($0) }
    let pixelBuffer = try makePixelBuffer(width: 320, height: 180)
    assertEqual(
      CVPixelBufferGetPixelFormatType(pixelBuffer),
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

    encoder.encode(
      pixelBuffer: pixelBuffer,
      presentationTime: .zero,
      duration: CMTime(value: 1, timescale: 30))
    try await finish(encoder)

    assertEqual(try output.sampleBuffers().count, 1)
  }

  @Test func testH264ConfigurationValidatesHigh42Envelope() throws {
    assertNoThrow(
      try H264VideoEncoderConfiguration(
        width: 1_920, height: 1_080, frameRate: 60, bitRate: 6_000_000
      ).validate())

    let invalid = [
      H264VideoEncoderConfiguration(
        width: 1_919, height: 1_080, frameRate: 60, bitRate: 6_000_000),
      H264VideoEncoderConfiguration(
        width: 1_920, height: 1_080, frameRate: 65, bitRate: 6_000_000),
      H264VideoEncoderConfiguration(
        width: 1_920, height: 1_080, frameRate: 60, bitRate: 62_500_001),
    ]
    for configuration in invalid {
      assertThrowsError(try configuration.validate())
    }
  }

  @Test func testAACEncoderRepresentsPrimingAndRemainderAsTrimMetadata() throws {
    let inputStartFrame = 48_000
    let inputFrameCount = 48_000
    let first = try makeAudioSample(startFrame: inputStartFrame, frameCount: 1_024)
    let encoder = try AACAudioEncoder(
      inputFormatDescription: try unwrap(first.formatDescription))
    var encoded = try encoder.encode(first)
    for relativeFrame in stride(from: 1_024, to: inputFrameCount, by: 1_024) {
      encoded.append(
        contentsOf: try encoder.encode(
          try makeAudioSample(
            startFrame: inputStartFrame + relativeFrame,
            frameCount: min(1_024, inputFrameCount - relativeFrame))))
    }
    encoded.append(contentsOf: try encoder.finish())

    let firstEncoded = try unwrap(encoded.first)
    let lastEncoded = try unwrap(encoded.last)
    let startTrim = trimDuration(
      firstEncoded,
      key: kCMSampleBufferAttachmentKey_TrimDurationAtStart)
    let endTrim = trimDuration(
      lastEncoded,
      key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
    let encodedFrameCount = encoded.reduce(0) {
      $0 + CMSampleBufferGetNumSamples($1) * 1_024
    }

    assertEqual(startTrim.value, 2_112)
    assertEqual(startTrim.timescale, 48_000)
    assertEqual(
      firstEncoded.presentationTimeStamp.seconds + startTrim.seconds,
      1,
      accuracy: 1.0 / 48_000)
    assertEqual(
      encodedFrameCount - Int(startTrim.seconds * 48_000) - Int(endTrim.seconds * 48_000),
      inputFrameCount)
  }

  @Test func testAACEncoderPublishesAudioSpecificConfig() throws {
    let input = try makeAudioSample(startFrame: 0, frameCount: 1_024)
    let encoder = try AACAudioEncoder(
      inputFormatDescription: try unwrap(input.formatDescription))

    var cookieSize = 0
    let cookie = CMAudioFormatDescriptionGetMagicCookie(
      encoder.outputFormatDescription,
      sizeOut: &cookieSize)

    assertNotNil(cookie)
    assertGreaterThan(cookieSize, 0)
  }

  @Test func testAACEncoderAcceptsContinuousPresentationTimes() throws {
    let first = try makeAudioSample(startFrame: 48_000, frameCount: 1_024)
    let encoder = try AACAudioEncoder(
      inputFormatDescription: try unwrap(first.formatDescription))

    assertNoThrow(try encoder.encode(first))
    assertNoThrow(try encoder.encode(makeAudioSample(startFrame: 49_024, frameCount: 1_024)))
  }

  @Test func testAACEncoderAcceptsSmallPresentationTimeRoundingDifference() throws {
    let first = try makeAudioSample(startFrame: 0, frameCount: 1_024)
    let encoder = try AACAudioEncoder(
      inputFormatDescription: try unwrap(first.formatDescription))

    _ = try encoder.encode(first)
    assertNoThrow(try encoder.encode(makeAudioSample(startFrame: 1_025, frameCount: 1_024)))
  }

  @Test func testAACEncoderRejectsAccumulatedPresentationTimeDrift() throws {
    let first = try makeAudioSample(startFrame: 0, frameCount: 1_024)
    let encoder = try AACAudioEncoder(
      inputFormatDescription: try unwrap(first.formatDescription))

    _ = try encoder.encode(first)
    _ = try encoder.encode(makeAudioSample(startFrame: 1_025, frameCount: 1_024))
    _ = try encoder.encode(makeAudioSample(startFrame: 2_050, frameCount: 1_024))
    assertThrowsError(try encoder.encode(makeAudioSample(startFrame: 3_075, frameCount: 1_024)))
  }

  @Test func testAACEncoderRejectsPresentationTimeGap() throws {
    let first = try makeAudioSample(startFrame: 0, frameCount: 1_024)
    let encoder = try AACAudioEncoder(
      inputFormatDescription: try unwrap(first.formatDescription))

    _ = try encoder.encode(first)
    assertThrowsError(try encoder.encode(makeAudioSample(startFrame: 1_034, frameCount: 1_024))) {
      guard case AACAudioEncoderError.discontinuousPresentationTime(_, _, let deltaFrames) = $0
      else { return fail("unexpected error: \($0)") }
      assertEqual(deltaFrames, 10, accuracy: 0.001)
    }
  }

  @Test func testAACEncoderRejectsPresentationTimeOverlap() throws {
    let first = try makeAudioSample(startFrame: 0, frameCount: 1_024)
    let encoder = try AACAudioEncoder(
      inputFormatDescription: try unwrap(first.formatDescription))

    _ = try encoder.encode(first)
    assertThrowsError(try encoder.encode(makeAudioSample(startFrame: 1_014, frameCount: 1_024))) {
      guard case AACAudioEncoderError.discontinuousPresentationTime(_, _, let deltaFrames) = $0
      else { return fail("unexpected error: \($0)") }
      assertEqual(deltaFrames, -10, accuracy: 0.001)
    }
  }

  @Test func testPassthroughWriterPersistsInvalidSampleFailure() async throws {
    let failureReported = expectation(description: "failure reported")
    let writer = try H264PassthroughSegmentedMP4Writer(
      targetSegmentDurationSeconds: 2,
      onFailure: { _ in failureReported.fulfill() },
      onSegment: { _ in })
    var invalidSample: CMSampleBuffer?
    assertEqual(
      CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: nil, sampleCount: 0,
        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0,
        sampleSizeArray: nil, sampleBufferOut: &invalidSample),
      noErr)

    writer.append(try unwrap(invalidSample))
    await fulfillment(of: [failureReported], timeout: 1)
    do {
      try await finish(writer)
      fail("finish should preserve the append failure")
    } catch {
      assertTrue(error is H264PassthroughSegmentedMP4WriterError)
    }
  }

  @Test func testPassthroughWriterFirstAppendFailsSynchronouslyWithoutFailureCallback() throws {
    let failureReported = expectation(description: "failure callback not reported before commit")
    failureReported.isInverted = true
    let writer = try H264PassthroughSegmentedMP4Writer(
      targetSegmentDurationSeconds: 2,
      onFailure: { _ in failureReported.fulfill() },
      onSegment: { _ in })
    var invalidSample: CMSampleBuffer?
    assertEqual(
      CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: nil, sampleCount: 0,
        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0,
        sampleSizeArray: nil, sampleBufferOut: &invalidSample),
      noErr)

    assertThrowsError(try writer.appendFirst(try unwrap(invalidSample)))
    wait(for: [failureReported], timeout: 0.05)
  }

  @Test func testPCMWriterWithoutSamplesOrPositiveEndDoesNotFabricateRecording() async throws {
    let sample = try makeAudioSample(startFrame: 0, frameCount: 1_024)
    for end in [CMTime?.none, .some(.zero), .some(CMTime(value: -1, timescale: 1))] {
      let output = H264SegmentOutput()
      let writer = try PCMAudioSegmentedMP4Writer(
        formatDescription: try unwrap(sample.formatDescription),
        targetSegmentDurationSeconds: 2
      ) { output.append($0) }
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        writer.finish(at: end) { continuation.resume(with: $0) }
      }
      assertTrue(output.values.isEmpty)
    }
  }

  @Test func testPCMWriterPersistsInjectedAppendFailure() async throws {
    let first = try makeAudioSample(startFrame: 0, frameCount: 1_024)
    let failureReported = expectation(description: "failure reported")
    let writer = try PCMAudioSegmentedMP4Writer(
      formatDescription: try unwrap(first.formatDescription),
      targetSegmentDurationSeconds: 2,
      onFailure: { _ in failureReported.fulfill() },
      onSegment: { _ in })

    writer.cancel(with: InjectedWriterError())
    await fulfillment(of: [failureReported], timeout: 1)
    do {
      try await finish(writer)
      fail("finish should preserve the append failure")
    } catch {
      assertTrue(error is InjectedWriterError)
    }
  }

  @Test func testPCMWriterPersistsSourceClockDrift() async throws {
    try await checkPCMWriterSourceClockDrift(drift: 100)
    try await checkPCMWriterSourceClockDrift(drift: -100)
  }

  private func checkPCMWriterSourceClockDrift(drift: Int64) async throws {
    let output = H264SegmentOutput()
    let first = try makeAudioSample(startFrame: 48_000, frameCount: 512)
    let writer = try PCMAudioSegmentedMP4Writer(
      formatDescription: try unwrap(first.formatDescription),
      targetSegmentDurationSeconds: 2
    ) { output.append($0) }
    for index in 0..<512 {
      let pcm = try makeAudioSample(startFrame: 48_000 + index * 512, frameCount: 512)
      var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: CMTime(
          value: 48_000_000 + Int64(index * 512) * 1_000 + Int64(index) * drift,
          timescale: 48_000_000), decodeTimeStamp: .invalid)
      var shifted: CMSampleBuffer?
      assertEqual(
        CMSampleBufferCreateCopyWithNewTiming(
          allocator: kCFAllocatorDefault, sampleBuffer: pcm, sampleTimingEntryCount: 1,
          sampleTimingArray: &timing, sampleBufferOut: &shifted), noErr)
      writer.append(try unwrap(shifted))
    }
    try await finish(writer)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PCMClockDrift-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try output.values.reduce(into: Data()) { $0.append($1.data) }.write(to: url)
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let reader = try AVAssetReader(asset: asset)
    let compressed = AVAssetReaderTrackOutput(
      track: try unwrap(tracks.first), outputSettings: nil)
    reader.add(compressed)
    assertTrue(reader.startReading())
    var packetTimes: [CMTime] = []
    while let sample = compressed.copyNextSampleBuffer() {
      for packet in 0..<CMSampleBufferGetNumSamples(sample) {
        let time = try sample.sampleTimingInfo(at: packet).presentationTimeStamp
        if time.seconds > 1.1 && time.seconds < 6 { packetTimes.append(time) }
      }
    }
    assertEqual(reader.status, .completed)
    assertGreaterThan(packetTimes.count, 100)
    let elapsed = CMTimeSubtract(try unwrap(packetTimes.last), try unwrap(packetTimes.first))
    // Each AAC packet spans two 512-frame input buffers, each shifted by
    // another 0.1 sample. Comparing elapsed time excludes priming/edit offsets.
    let expected = CMTime(
      value: Int64(packetTimes.count - 1) * (1_024_000 + drift * 2), timescale: 48_000_000)
    assertEqual(elapsed.seconds, expected.seconds, accuracy: 1.0 / 48_000_000)
  }

  @Test func testRecordingClockDiscardsEmittedHistoryWithoutChangingFutureMapping() throws {
    let clock = RecordingPCMClock(sampleRate: 48_000)
    for batch in 0..<100 {
      for index in 0..<32 {
        let frame = (batch * 32 + index) * 512
        _ = try clock.converterSample(makeAudioSample(startFrame: frame + 48_000, frameCount: 512))
      }
      assertLessThanOrEqual(clock.retainedAnchorCount, 33)
      let end = CMTime(value: Int64((batch + 1) * 32 * 512 + 48_000), timescale: 48_000)
      assertEqual(CMTimeCompare(try clock.sourceTime(for: end), end), 0)
      clock.discardEmittedHistory()
      assertEqual(clock.retainedAnchorCount, 1)
      assertEqual(CMTimeCompare(try clock.sourceTime(for: end), end), 0)
    }
    assertThrowsError(try clock.sourceTime(for: CMTime(value: 1, timescale: 1)))
  }

  @Test func testPCMWriterPreservesDurationAcrossSampleRateChanges() async throws {
    for (middleRate, middleChannels) in [
      (48_000, 2), (44_100, 2), (96_000, 2), (48_000, 1), (44_100, 1),
    ] {
      let output = H264SegmentOutput()
      let first = try makeAudioSample(startFrame: 0, frameCount: 1_024)
      let writer = try PCMAudioSegmentedMP4Writer(
        formatDescription: try unwrap(first.formatDescription),
        targetSegmentDurationSeconds: 2
      ) { output.append($0) }
      // Contiguous intervals: 1 second at 48 kHz, 20 at the test rate, 1 at 48 kHz.
      for (rate, startSecond, seconds) in [(48_000, 0, 1), (middleRate, 1, 20), (48_000, 21, 1)] {
        for frame in stride(from: 0, to: rate * seconds, by: 1_024) {
          writer.append(
            try makeAudioSample(
              startFrame: rate * startSecond + frame,
              frameCount: min(1_024, rate * seconds - frame), sampleRate: rate,
              channelCount: startSecond == 1 ? middleChannels : 2))
        }
      }
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        writer.finish(at: CMTime(value: 22, timescale: 1)) { continuation.resume(with: $0) }
      }
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "PCMRateChange-\(UUID().uuidString).mp4")
      defer { try? FileManager.default.removeItem(at: url) }
      try output.values.reduce(into: Data()) { $0.append($1.data) }.write(to: url)
      let duration = try await AVURLAsset(url: url).load(.duration)
      print("PCM_FORMAT_TEST", middleRate, middleChannels, "duration", duration.seconds)
      assertEqual(duration.seconds, 22, accuracy: 0.1, "Middle sample rate: \(middleRate)")
      let asset = AVURLAsset(url: url)
      let tracks = try await asset.loadTracks(withMediaType: .audio)
      let reader = try AVAssetReader(asset: asset)
      let decoded = AVAssetReaderTrackOutput(
        track: try unwrap(tracks.first),
        outputSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsNonInterleaved: false,
        ])
      reader.add(decoded)
      assertTrue(reader.startReading())
      let windows = [0.2..<0.8, 5.0..<6.0, 19.0..<20.0, 21.2..<21.8]
      var energy = Array(repeating: 0.0, count: windows.count)
      var counts = Array(repeating: 0, count: windows.count)
      var crossings = Array(repeating: 0, count: windows.count)
      var previous = Array(repeating: Float(0), count: windows.count)
      while let sample = decoded.copyNextSampleBuffer() {
        let block = try unwrap(sample.dataBuffer)
        var values = Array(repeating: Float(0), count: CMBlockBufferGetDataLength(block) / 4)
        assertEqual(
          values.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(
              block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
          }, noErr)
        for frame in 0..<(values.count / 2) {
          let time = sample.presentationTimeStamp.seconds + Double(frame) / 48_000
          let value = values[frame * 2]
          for index in windows.indices where windows[index].contains(time) {
            energy[index] += Double(value) * Double(value)
            if counts[index] > 0 && previous[index] <= 0 && value > 0 { crossings[index] += 1 }
            previous[index] = value
            counts[index] += 1
          }
        }
      }
      assertEqual(reader.status, .completed)
      for index in windows.indices {
        assertGreaterThan(counts[index], 20_000)
        assertGreaterThan(sqrt(energy[index] / Double(max(counts[index], 1))), 0.05)
        assertEqual(
          Double(crossings[index]) * 48_000 / Double(max(counts[index], 1)), 440, accuracy: 5)
      }
    }
  }

  @Test func testPCMWriterPreservesMissingInputInterval() async throws {
    let output = H264SegmentOutput()
    let first = try makeAudioSample(startFrame: 0, frameCount: 1_024)
    let writer = try PCMAudioSegmentedMP4Writer(
      formatDescription: try unwrap(first.formatDescription),
      targetSegmentDurationSeconds: 2
    ) { output.append($0) }
    // One second captured, two seconds disconnected, one second captured.
    for range in [0..<48_000, 144_000..<192_000] {
      for start in stride(from: range.lowerBound, to: range.upperBound, by: 1_024) {
        writer.append(
          try makeAudioSample(
            startFrame: start, frameCount: min(1_024, range.upperBound - start)))
      }
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      writer.finish(at: CMTime(value: 5, timescale: 1)) {
        continuation.resume(with: $0)
      }
    }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("PCMGap-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try output.values.reduce(into: Data()) { $0.append($1.data) }.write(to: url)
    let duration = try await AVURLAsset(url: url).load(.duration)
    assertEqual(duration.seconds, 5, accuracy: 0.1)
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let reader = try AVAssetReader(asset: asset)
    let decoded = AVAssetReaderTrackOutput(
      track: try unwrap(tracks.first),
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsNonInterleaved: false,
      ])
    reader.add(decoded)
    assertTrue(reader.startReading())
    let windows = [0.2..<0.8, 1.2..<2.8, 3.2..<3.8, 4.2..<4.8]
    var energy = Array(repeating: 0.0, count: windows.count)
    var counts = Array(repeating: 0, count: windows.count)
    while let sample = decoded.copyNextSampleBuffer() {
      let block = try unwrap(sample.dataBuffer)
      var values = Array(repeating: Float(0), count: CMBlockBufferGetDataLength(block) / 4)
      let status = values.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(
          block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
      }
      assertEqual(status, noErr)
      for frame in 0..<(values.count / 2) {
        let time = sample.presentationTimeStamp.seconds + Double(frame) / 48_000
        for index in windows.indices where windows[index].contains(time) {
          energy[index] += Double(values[frame * 2]) * Double(values[frame * 2])
          counts[index] += 1
        }
      }
    }
    assertEqual(reader.status, .completed)
    for index in windows.indices {
      assertGreaterThan(counts[index], 0)
      let rms = sqrt(energy[index] / Double(max(counts[index], 1)))
      if index == 0 || index == 2 {
        assertGreaterThan(rms, 0.05, "Captured sound must retain its timeline position")
      } else {
        assertLessThan(rms, 0.001, "Missing input must decode as silence")
      }
    }
  }

  @Test func testMonoRecordingWithoutInputFinalizes() async throws {
    let output = H264SegmentOutput()
    let sample = try makeAudioSample(startFrame: 0, frameCount: 512, channelCount: 1)
    let writer = try PCMAudioSegmentedMP4Writer(
      formatDescription: unwrap(sample.formatDescription), targetSegmentDurationSeconds: 2
    ) { output.append($0) }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      writer.finish(at: CMTime(value: 66, timescale: 1)) { continuation.resume(with: $0) }
    }
    assertGreaterThan(output.values.count, 1)
  }

  @Test func testMonoRecordingWithSubsampleStartFinalizes() async throws {
    let output = H264SegmentOutput()
    let first = try makeAudioSample(startFrame: 0, frameCount: 512, channelCount: 1)
    let writer = try PCMAudioSegmentedMP4Writer(
      formatDescription: unwrap(first.formatDescription), targetSegmentDurationSeconds: 2
    ) { output.append($0) }
    for frame in stride(from: 0, to: 48_000, by: 512) {
      let input = try makeAudioSample(
        startFrame: frame, frameCount: min(512, 48_000 - frame), channelCount: 1)
      var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: CMTimeAdd(
          CMTime(value: Int64(frame), timescale: 48_000),
          CMTime(value: 20_000, timescale: 1_000_000_000)),
        decodeTimeStamp: .invalid)
      var shifted: CMSampleBuffer?
      assertEqual(
        CMSampleBufferCreateCopyWithNewTiming(
          allocator: kCFAllocatorDefault, sampleBuffer: input, sampleTimingEntryCount: 1,
          sampleTimingArray: &timing, sampleBufferOut: &shifted), noErr)
      writer.append(try unwrap(shifted))
    }
    try await finish(writer)
    assertGreaterThan(output.values.count, 1)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MonoSubsampleStart-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try output.values.reduce(into: Data()) { $0.append($1.data) }.write(to: url)
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let reader = try AVAssetReader(asset: asset)
    let compressed = AVAssetReaderTrackOutput(
      track: try unwrap(tracks.first), outputSettings: nil)
    reader.add(compressed)
    assertTrue(reader.startReading())
    let firstPacket = try unwrap(compressed.copyNextSampleBuffer())
    for segment in output.values {
      for box in try MP4TimingBox.parse(segment.data) where box.type == MP4TimingBox.fourCC("moof")
      {
        for traf in try MP4TimingBox.parse(box.payload)
        where traf.type == MP4TimingBox.fourCC("traf") {
          for tfdt in try MP4TimingBox.parse(traf.payload)
          where tfdt.type == MP4TimingBox.fourCC("tfdt") {
            assertEqual(try MP4TimingBox.read(tfdt.payload, at: 4, bytes: 8), 20_000)
          }
        }
      }
    }
    while compressed.copyNextSampleBuffer() != nil {}
    assertEqual(reader.status, .completed)
    let pcmReader = try AVAssetReader(asset: asset)
    let pcmOutput = AVAssetReaderTrackOutput(
      track: try unwrap(tracks.first),
      outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
    pcmReader.add(pcmOutput)
    assertTrue(pcmReader.startReading())
    let decoded = try unwrap(pcmOutput.copyNextSampleBuffer())
    // Compressed buffers can start before the source signal because they
    // include AAC priming. Verify the actual decoded PCM placement instead.
    assertLessThanOrEqual(firstPacket.presentationTimeStamp, decoded.presentationTimeStamp)
    // AVAssetReader renders PCM on the sample-rate grid. The fragment check
    // above verifies sub-sample storage; package/remux tests verify placement.
    assertGreaterThan(decoded.numSamples, 0)
    while pcmOutput.copyNextSampleBuffer() != nil {}
    assertEqual(pcmReader.status, .completed)
  }

  @Test func testPCMWriterPreservesSmallPresentationStartOffset() async throws {
    let output = H264SegmentOutput()
    let first = try makeAudioSample(startFrame: 48_000, frameCount: 1_024)
    let writer = try PCMAudioSegmentedMP4Writer(
      formatDescription: try unwrap(first.formatDescription),
      targetSegmentDurationSeconds: 2
    ) { output.append($0) }
    writer.append(first)
    for startFrame in stride(from: 49_024, to: 192_000, by: 1_024) {
      writer.append(
        try makeAudioSample(
          startFrame: startFrame,
          frameCount: min(1_024, 192_000 - startFrame)
        )
      )
    }
    try await finish(writer)

    let firstMedia = try unwrap(
      output.values.first {
        if case .media = $0.kind { return true }
        return false
      }
    )
    assertEqual(firstMedia.earliestPresentationTimeSeconds ?? -1, 0.956, accuracy: 0.002)
  }

  @Test func testManualPassthroughWriterProducesPlayableAudioVideoFragments() async throws {
    let encoded = H264EncoderOutput()
    let encoder = try H264VideoEncoder(
      configuration: H264VideoEncoderConfiguration(
        width: 320, height: 180, frameRate: 30, bitRate: 800_000)
    ) { encoded.append($0) }
    for index in 0..<101 {
      // Every keyframe, including intentionally short 0.2- and 1-second GOPs,
      // must become exactly one independently decodable media segment.
      if index == 6 || index == 36 || index == 96 { encoder.requestKeyFrame() }
      encoder.encode(
        pixelBuffer: try makePixelBuffer(width: 320, height: 180),
        presentationTime: CMTime(value: CMTimeValue(index), timescale: 30),
        duration: CMTime(value: 1, timescale: 30))
    }
    try await finish(encoder)

    let videoSamples = try encoded.sampleBuffers()
    let firstVideo = try unwrap(videoSamples.first)
    assertTrue(isKeyFrame(videoSamples[6]))
    assertTrue(isKeyFrame(videoSamples[36]))
    assertTrue(isKeyFrame(videoSamples[96]))
    let firstAudio = try makeAudioSample(startFrame: 0, frameCount: 1_024)
    let audioEncoder = try AACAudioEncoder(
      inputFormatDescription: try unwrap(firstAudio.formatDescription))
    var audioSamples = try audioEncoder.encode(firstAudio)
    for startFrame in stride(from: 1_024, to: 192_000, by: 1_024) {
      audioSamples.append(
        contentsOf: try audioEncoder.encode(
          try makeAudioSample(
            startFrame: startFrame, frameCount: min(1_024, 192_000 - startFrame))))
    }
    audioSamples.append(contentsOf: try audioEncoder.finish())

    let segments = H264SegmentOutput()
    let writer = try MuxedPassthroughSegmentedMP4Writer(
      videoFormatDescription: try unwrap(firstVideo.formatDescription),
      audioFormatDescription: audioEncoder.outputFormatDescription
    ) { segments.append($0) }
    // Deliver the tracks separately to exercise the cross-batch watermark. The
    // writer must not flush at a video keyframe before earlier audio arrives.
    writer.append(video: videoSamples, audio: [])
    writer.append(video: [], audio: audioSamples)
    try await finish(writer)

    let mediaSegments = segments.values.filter {
      if case .media = $0.kind { return true }
      return false
    }
    let keyFrameCount = videoSamples.filter(isKeyFrame).count
    assertEqual(mediaSegments.count, keyFrameCount)
    assertEqual(
      mediaSegments.compactMap(\.diagnostics).reduce(0) { $0 + $1.videoSampleCount },
      videoSamples.count)
    assertEqual(
      mediaSegments.compactMap(\.diagnostics).reduce(0) { $0 + $1.syncVideoSampleCount },
      videoSamples.filter(isKeyFrame).count)
    assertGreaterThan(
      mediaSegments.compactMap(\.diagnostics).reduce(0) { $0 + $1.audioFrameCount },
      0)
    assertTrue(
      mediaSegments.compactMap(\.diagnostics).allSatisfy { $0.syncVideoSampleCount == 1 })
    var output = try unwrap(
      segments.values.first { $0.kind == .initialization }?.data)
    for segment in mediaSegments { output.append(segment.data) }

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    try output.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let asset = AVURLAsset(url: url)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    assertEqual(videoTracks.count, 1)
    assertEqual(audioTracks.count, 1)

    let audioReader = try AVAssetReader(asset: asset)
    let compressedAudioOutput = AVAssetReaderTrackOutput(
      track: try unwrap(audioTracks.first),
      outputSettings: nil)
    assertTrue(audioReader.canAdd(compressedAudioOutput))
    audioReader.add(compressedAudioOutput)
    assertTrue(audioReader.startReading())
    let firstCompressedAudio = try unwrap(compressedAudioOutput.copyNextSampleBuffer())
    assertEqual(
      trimDuration(
        firstCompressedAudio,
        key: kCMSampleBufferAttachmentKey_TrimDurationAtStart
      ).seconds,
      2_112.0 / 48_000,
      accuracy: 1.0 / 48_000)

    let reader = try AVAssetReader(asset: asset)
    let videoOutput = AVAssetReaderTrackOutput(
      track: try unwrap(videoTracks.first),
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ])
    assertTrue(reader.canAdd(videoOutput))
    reader.add(videoOutput)
    assertTrue(reader.startReading())
    var decodedFrameCount = 0
    while videoOutput.copyNextSampleBuffer() != nil {
      decodedFrameCount += 1
    }
    assertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "")
    assertGreaterThan(decodedFrameCount, 0)
  }

  @Test func testPassthroughSegmentWriterProducesVideoOnlyFragments() async throws {
    let output = H264EncoderOutput()
    let encoder = try H264VideoEncoder(
      configuration: H264VideoEncoderConfiguration(
        width: 320,
        height: 180,
        frameRate: 30,
        bitRate: 800_000
      )
    ) { output.append($0) }
    for index in 0..<90 {
      encoder.encode(
        pixelBuffer: try makePixelBuffer(width: 320, height: 180),
        presentationTime: CMTime(value: CMTimeValue(index), timescale: 30),
        duration: CMTime(value: 1, timescale: 30)
      )
    }
    try await finish(encoder)

    let segments = H264SegmentOutput()
    let writer = try H264PassthroughSegmentedMP4Writer(targetSegmentDurationSeconds: 2) {
      segments.append($0)
    }
    let sampleBuffers = try output.sampleBuffers()
    try writer.appendFirst(try unwrap(sampleBuffers.first))
    for sampleBuffer in sampleBuffers.dropFirst() {
      writer.append(sampleBuffer)
    }
    try await withCheckedThrowingContinuation { continuation in
      writer.finish { continuation.resume(with: $0) }
    }

    assertTrue(segments.values.contains { $0.kind == .initialization })
    assertTrue(
      segments.values.contains {
        if case .media = $0.kind { return true }
        return false
      })
  }

  @Test
  func testHeavyVideoToolboxPreservesLargePTSInSDR1080p60CBRContract() async throws {
    let output = H264EncoderOutput()
    let encoder = try H264VideoEncoder(
      configuration: H264VideoEncoderConfiguration(
        width: 1_920,
        height: 1_080,
        frameRate: 60,
        bitRate: 6_000_000,
        keyFrameIntervalSeconds: 2,
        requiresHardwareAcceleration: true
      )
    ) { result in
      output.append(result)
    }

    let startFrame = CMTimeValue(60 * 60 * 60 * 36)
    for index in 0..<150 {
      encoder.encode(
        pixelBuffer: try makePixelBuffer(width: 1_920, height: 1_080),
        presentationTime: CMTime(value: startFrame + CMTimeValue(index), timescale: 60),
        duration: CMTime(value: 1, timescale: 60)
      )
    }
    try await finish(encoder)

    let sampleBuffers = try output.sampleBuffers()
    let keyFrameIndices = sampleBuffers.indices.filter { isKeyFrame(sampleBuffers[$0]) }
    assertEqual(sampleBuffers.count, 150)
    assertEqual(
      sampleBuffers.first?.presentationTimeStamp, CMTime(value: startFrame, timescale: 60))
    for pair in zip(sampleBuffers, sampleBuffers.dropFirst()) {
      assertTrue(pair.0.presentationTimeStamp.isValid)
      assertGreaterThan(pair.1.presentationTimeStamp, pair.0.presentationTimeStamp)
    }
    assertEqual(keyFrameIndices.first, 0)
    assertGreaterThanOrEqual(keyFrameIndices.count, 2)
    for pair in zip(keyFrameIndices, keyFrameIndices.dropFirst()) {
      assertLessThanOrEqual(pair.1 - pair.0, 120)
    }
    assertEqual(try H264VideoEncoder.codecString(from: sampleBuffers[0]), "avc1.64002a")
    let encodedBytes = sampleBuffers.reduce(0) {
      $0 + ($1.dataBuffer.map(CMBlockBufferGetDataLength) ?? 0)
    }
    let measuredBitRate = Double(encodedBytes * 8) / (Double(sampleBuffers.count) / 60)
    // Hardware rate control needs a longer stream for a precise convergence measurement.
    // This short contract test catches a missing/ineffective CBR setting without pretending
    // to replace the device-matrix soak measurement.
    assertEqual(measuredBitRate, 6_000_000, accuracy: 1_500_000)
  }

  @Test func testEncoderProducesAVCCWithoutFrameReorderingAndCanForceKeyFrame() async throws {
    let output = H264EncoderOutput()
    let encoder = try H264VideoEncoder(
      configuration: H264VideoEncoderConfiguration(
        width: 320,
        height: 180,
        frameRate: 30,
        bitRate: 800_000
      )
    ) { result in
      output.append(result)
    }

    for index in 0..<3 {
      if index == 1 {
        encoder.requestKeyFrame()
      }
      encoder.encode(
        pixelBuffer: try makePixelBuffer(width: 320, height: 180),
        presentationTime: CMTime(value: CMTimeValue(index), timescale: 30),
        duration: CMTime(value: 1, timescale: 30)
      )
    }
    try await finish(encoder)

    let sampleBuffers = try output.sampleBuffers()
    assertEqual(sampleBuffers.count, 3)
    assertTrue(isKeyFrame(sampleBuffers[0]))
    assertTrue(isKeyFrame(sampleBuffers[1]))

    for (index, sampleBuffer) in sampleBuffers.enumerated() {
      assertEqual(
        sampleBuffer.presentationTimeStamp, CMTime(value: CMTimeValue(index), timescale: 30))
      let decodeTime = sampleBuffer.decodeTimeStamp
      assertTrue(!decodeTime.isValid || decodeTime == sampleBuffer.presentationTimeStamp)
      try assertContainsValidAVCCAccessUnit(sampleBuffer)
    }
    try assertContainsH264ParameterSets(sampleBuffers[0])
    assertEqual(try H264VideoEncoder.codecString(from: sampleBuffers[0]), "avc1.64002a")
  }

  @Test func testEncoderKeepsKeyFrameIntervalWithinTwoSeconds() async throws {
    let output = H264EncoderOutput()
    let encoder = try H264VideoEncoder(
      configuration: H264VideoEncoderConfiguration(
        width: 320,
        height: 180,
        frameRate: 30,
        bitRate: 800_000,
        keyFrameIntervalSeconds: 2
      )
    ) { result in
      output.append(result)
    }

    for index in 0..<70 {
      encoder.encode(
        pixelBuffer: try makePixelBuffer(width: 320, height: 180),
        presentationTime: CMTime(value: CMTimeValue(index), timescale: 30),
        duration: CMTime(value: 1, timescale: 30))
    }
    try await finish(encoder)

    let sampleBuffers = try output.sampleBuffers()
    let keyFrameIndices = sampleBuffers.indices.filter { isKeyFrame(sampleBuffers[$0]) }
    assertEqual(sampleBuffers.count, 70)
    assertGreaterThanOrEqual(keyFrameIndices.count, 2)
    assertEqual(keyFrameIndices.first, 0)
    assertTrue(keyFrameIndices.contains(60))
    for pair in zip(keyFrameIndices, keyFrameIndices.dropFirst()) {
      assertLessThanOrEqual(pair.1 - pair.0, 60)
    }
    assertLessThanOrEqual(69 - (try unwrap(keyFrameIndices.last)), 60)
  }

  private func finish(_ encoder: H264VideoEncoder) async throws {
    try await withCheckedThrowingContinuation { continuation in
      encoder.finish { result in
        continuation.resume(with: result)
      }
    }
  }

  private func finish(_ writer: H264PassthroughSegmentedMP4Writer) async throws {
    try await withCheckedThrowingContinuation { continuation in
      writer.finish { continuation.resume(with: $0) }
    }
  }

  private func finish(_ writer: PCMAudioSegmentedMP4Writer) async throws {
    try await withCheckedThrowingContinuation { continuation in
      writer.finish { continuation.resume(with: $0) }
    }
  }

  private func finish(_ writer: MuxedPassthroughSegmentedMP4Writer) async throws {
    try await withCheckedThrowingContinuation { continuation in
      writer.finish { continuation.resume(with: $0) }
    }
  }

  private func makeAudioSample(
    startFrame: Int, frameCount: Int, sampleRate: Int = 48_000, channelCount: Int = 2
  ) throws
    -> CMSampleBuffer
  {
    var data = Data(count: frameCount * channelCount * MemoryLayout<Float32>.size)
    data.withUnsafeMutableBytes { bytes in
      let samples = bytes.bindMemory(to: Float32.self)
      for frame in 0..<frameCount {
        let value = Float32(
          sin(2 * Double.pi * 440 * Double(startFrame + frame) / Double(sampleRate)) * 0.2)
        for channel in 0..<channelCount { samples[frame * channelCount + channel] = value }
      }
    }
    var block: CMBlockBuffer?
    assertEqual(
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
        blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
        dataLength: data.count, flags: 0, blockBufferOut: &block),
      kCMBlockBufferNoErr)
    let unwrappedBlock = try unwrap(block)
    data.withUnsafeBytes {
      assertEqual(
        CMBlockBufferReplaceDataBytes(
          with: $0.baseAddress!, blockBuffer: unwrappedBlock, offsetIntoDestination: 0,
          dataLength: data.count),
        kCMBlockBufferNoErr)
    }
    var stream = AudioStreamBasicDescription(
      mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(channelCount * 4), mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(channelCount * 4),
      mChannelsPerFrame: UInt32(channelCount), mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    assertEqual(
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &stream, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format),
      noErr)
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
      presentationTimeStamp: CMTime(
        value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate)),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    assertEqual(
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: unwrappedBlock,
        formatDescription: try unwrap(format), sampleCount: frameCount,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample),
      noErr)
    return try unwrap(sample)
  }

  private func trimDuration(_ sample: CMSampleBuffer, key: CFString) -> CMTime {
    guard
      let attachment = CMGetAttachment(sample, key: key, attachmentModeOut: nil),
      CFGetTypeID(attachment) == CFDictionaryGetTypeID()
    else { return .zero }
    return CMTimeMakeFromDictionary((attachment as! CFDictionary))
  }

  private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
      &pixelBuffer
    )
    assertEqual(status, kCVReturnSuccess)
    return try unwrap(pixelBuffer)
  }

  private func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: false
      ) as? [[CFString: Any]],
      let first = attachments.first
    else {
      return true
    }
    return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
  }

  private func assertContainsValidAVCCAccessUnit(_ sampleBuffer: CMSampleBuffer) throws {
    let dataBuffer = try unwrap(sampleBuffer.dataBuffer)
    let byteCount = CMBlockBufferGetDataLength(dataBuffer)
    assertGreaterThan(byteCount, 4)
    var bytes = [UInt8](repeating: 0, count: byteCount)
    assertEqual(
      CMBlockBufferCopyDataBytes(
        dataBuffer,
        atOffset: 0,
        dataLength: byteCount,
        destination: &bytes
      ),
      kCMBlockBufferNoErr
    )
    let firstNALUnitLength = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    assertGreaterThan(firstNALUnitLength, 0)
    assertLessThanOrEqual(firstNALUnitLength, byteCount - 4)
  }

  private func assertContainsH264ParameterSets(_ sampleBuffer: CMSampleBuffer) throws {
    let formatDescription = try unwrap(sampleBuffer.formatDescription)
    var parameterSetCount = 0
    var nalUnitHeaderLength: Int32 = 0
    let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      formatDescription,
      parameterSetIndex: 0,
      parameterSetPointerOut: nil,
      parameterSetSizeOut: nil,
      parameterSetCountOut: &parameterSetCount,
      nalUnitHeaderLengthOut: &nalUnitHeaderLength
    )
    assertEqual(status, noErr)
    assertGreaterThanOrEqual(parameterSetCount, 2)
    assertEqual(nalUnitHeaderLength, 4)
  }
}

private final class TestExpectation: @unchecked Sendable {
  let description: String
  var isInverted = false
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var fulfillmentCount = 0

  init(description: String) { self.description = description }

  var fulfilled: Bool { lock.withLock { fulfillmentCount > 0 } }

  func fulfill() {
    lock.withLock { fulfillmentCount += 1 }
    semaphore.signal()
  }

  func wait(until deadline: DispatchTime) -> Bool {
    semaphore.wait(timeout: deadline) == .success
  }
}

private struct TestFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

private func expectation(description: String) -> TestExpectation {
  TestExpectation(description: description)
}

private func fulfillment(of expectations: [TestExpectation], timeout: TimeInterval) async {
  let deadline = DispatchTime.now() + timeout
  for expectation in expectations {
    let fulfilled = await Task.detached { expectation.wait(until: deadline) }.value
    if expectation.isInverted {
      if fulfilled {
        Issue.record(TestFailure("Unexpectedly fulfilled \(expectation.description)"))
      }
    } else if !fulfilled {
      Issue.record(TestFailure("Timed out waiting for \(expectation.description)"))
    }
  }
}

private func wait(for expectations: [TestExpectation], timeout: TimeInterval) {
  let deadline = Date().addingTimeInterval(timeout)
  for expectation in expectations {
    if expectation.isInverted {
      while !expectation.fulfilled && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
      }
      if expectation.fulfilled {
        Issue.record(TestFailure("Unexpectedly fulfilled \(expectation.description)"))
      }
    } else {
      while !expectation.wait(until: .now()) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
      }
      if !expectation.fulfilled {
        Issue.record(TestFailure("Timed out waiting for \(expectation.description)"))
      }
    }
  }
}

private func assertEqual<Value: Equatable>(_ actual: Value, _ expected: Value, _: String? = nil) {
  if actual != expected { Issue.record(TestFailure("Expected \(expected), got \(actual)")) }
}

private func assertEqual<Value: BinaryFloatingPoint>(
  _ actual: Value, _ expected: Value, accuracy: Value, _: String? = nil
) {
  if abs(actual - expected) > accuracy {
    Issue.record(TestFailure("Expected \(expected) +/- \(accuracy), got \(actual)"))
  }
}

private func assertTrue(_ value: Bool, _: String? = nil) {
  if !value { Issue.record(TestFailure("Expected true")) }
}

private func assertFalse(_ value: Bool, _: String? = nil) {
  if value { Issue.record(TestFailure("Expected false")) }
}

private func assertNil<Value>(_ value: Value?, _: String? = nil) {
  if value != nil { Issue.record(TestFailure("Expected nil")) }
}

private func assertNotNil<Value>(_ value: Value?, _: String? = nil) {
  if value == nil { Issue.record(TestFailure("Expected non-nil value")) }
}

private func assertGreaterThan<Value: Comparable>(
  _ actual: Value, _ expected: Value, _: String? = nil
) {
  if actual <= expected {
    Issue.record(TestFailure("Expected \(actual) to be greater than \(expected)"))
  }
}

private func assertGreaterThanOrEqual<Value: Comparable>(
  _ actual: Value, _ expected: Value, _: String? = nil
) {
  if actual < expected {
    Issue.record(TestFailure("Expected \(actual) to be at least \(expected)"))
  }
}

private func assertLessThan<Value: Comparable>(_ actual: Value, _ expected: Value, _: String? = nil)
{
  if actual >= expected {
    Issue.record(TestFailure("Expected \(actual) to be less than \(expected)"))
  }
}

private func assertLessThanOrEqual<Value: Comparable>(
  _ actual: Value, _ expected: Value, _: String? = nil
) {
  if actual > expected { Issue.record(TestFailure("Expected \(actual) to be at most \(expected)")) }
}

private func assertNoThrow<Value>(_ expression: @autoclosure () throws -> Value) {
  do { _ = try expression() } catch { Issue.record(error) }
}

private func assertThrowsError<Value>(
  _ expression: @autoclosure () throws -> Value,
  _ handler: (Error) -> Void = { _ in }
) {
  do {
    _ = try expression()
    Issue.record(TestFailure("Expected an error"))
  } catch {
    handler(error)
  }
}

private func fail(_ message: String = "Test failed") { Issue.record(TestFailure(message)) }

private func unwrap<Value>(_ value: Value?) throws -> Value { try #require(value) }

private struct InjectedWriterError: Error {}

private final class H264EncoderOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Result<CMSampleBuffer, any Error>] = []

  func append(_ result: Result<CMSampleBuffer, any Error>) {
    lock.withLock {
      results.append(result)
    }
  }

  func sampleBuffers() throws -> [CMSampleBuffer] {
    try lock.withLock {
      try results.map { try $0.get() }
    }
  }
}

private final class H264SegmentOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var segments: [SegmentedMP4Segment] = []

  var values: [SegmentedMP4Segment] { lock.withLock { segments } }

  func append(_ segment: SegmentedMP4Segment) {
    lock.withLock { segments.append(segment) }
  }
}
