// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import LDTXMP4
import LDTXRecording
import Testing

@testable import LDTXProgramRuntime

private final class StressDiscardingSegmentDelegate: NSObject, AVAssetWriterDelegate {
  func assetWriter(
    _ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
    segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?
  ) {}
}

@Suite(.serialized)
struct AudioSideStreamSegmentPipelineHardTests {
  private let stressRounds = 30

  @Test
  func aacPassthroughAssetWriterLifecycleStress() async throws {
    for round in 0..<stressRounds {
      let delegate = StressDiscardingSegmentDelegate()
      let first = try makeSyntheticAudioSample(startFrame: 9_600, frameCount: 1_024)
      let encoder = try AACAudioEncoder(
        inputFormatDescription: try #require(first.formatDescription))
      var samples: [CMSampleBuffer] = []
      for startFrame in stride(from: 0, to: 144_000, by: 1_024) {
        samples.append(
          contentsOf: try encoder.encode(
            try makeSyntheticAudioSample(
              startFrame: startFrame + 9_600, frameCount: min(1_024, 144_000 - startFrame))))
      }
      samples.append(contentsOf: try encoder.finish())
      let writer = AVAssetWriter(contentType: .mpeg4Movie)
      writer.outputFileTypeProfile = .mpeg4AppleHLS
      writer.preferredOutputSegmentInterval = CMTime(value: 2, timescale: 1)
      writer.initialSegmentStartTime = .zero
      writer.delegate = delegate
      let input = AVAssetWriterInput(
        mediaType: .audio, outputSettings: nil,
        sourceFormatHint: encoder.outputFormatDescription)
      input.expectsMediaDataInRealTime = true
      writer.add(input)
      try writer.start()
      writer.startSession(atSourceTime: .zero)
      for sample in samples {
        while !input.isReadyForMoreMediaData {
          try #require(writer.status == .writing)
          try await Task.sleep(for: .milliseconds(1))
        }
        try #require(input.append(sample))
      }
      input.markAsFinished()
      await withCheckedContinuation { continuation in
        writer.finishWriting { continuation.resume() }
      }
      try #require(writer.status == .completed)
      withExtendedLifetime(delegate) {}
      print("AAC_PASSTHROUGH_WRITER_STRESS completed round \(round + 1)")
    }
  }

  @Test
  func directPCMAssetWriterLifecycleStress() async throws {
    for round in 0..<stressRounds {
      let delegate = StressDiscardingSegmentDelegate()
      let first = try makeSyntheticAudioSample(startFrame: 9_600, frameCount: 1_024)
      let writer = AVAssetWriter(contentType: .mpeg4Movie)
      writer.outputFileTypeProfile = .mpeg4AppleHLS
      writer.preferredOutputSegmentInterval = CMTime(value: 2, timescale: 1)
      writer.initialSegmentStartTime = .zero
      writer.delegate = delegate
      let input = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: 48_000,
          AVNumberOfChannelsKey: 2,
          AVEncoderBitRateKey: 128_000,
        ], sourceFormatHint: first.formatDescription)
      input.expectsMediaDataInRealTime = true
      writer.add(input)
      try writer.start()
      writer.startSession(atSourceTime: .zero)
      for startFrame in stride(from: 0, to: 144_000, by: 1_024) {
        while !input.isReadyForMoreMediaData {
          try #require(writer.status == .writing)
          try await Task.sleep(for: .milliseconds(1))
        }
        try #require(
          input.append(
            try makeSyntheticAudioSample(
              startFrame: startFrame + 9_600, frameCount: min(1_024, 144_000 - startFrame))))
      }
      input.markAsFinished()
      await withCheckedContinuation { continuation in
        writer.finishWriting { continuation.resume() }
      }
      try #require(writer.status == .completed)
      withExtendedLifetime(delegate) {}
      print("DIRECT_PCM_WRITER_STRESS completed round \(round + 1)")
    }
  }

  @Test
  func mainWriterOnlyLifecycleStress() async throws {
    for round in 0..<stressRounds {
      try await runSyntheticRecording(disconnect: 0, includeRemux: false, includeSide: false)
      print("MAIN_WRITER_STRESS completed round \(round + 1)")
    }
  }

  @Test
  func pcmWriterOnlyLifecycleStress() async throws {
    for round in 0..<stressRounds {
      let first = try makeSyntheticAudioSample(startFrame: 0, frameCount: 1_024)
      let writer = try PCMAudioSegmentedMP4Writer(
        formatDescription: try #require(first.formatDescription),
        targetSegmentDurationSeconds: 2,
        onSegment: { _ in })
      for startFrame in stride(from: 0, to: 144_000, by: 1_024) {
        writer.append(
          try makeSyntheticAudioSample(
            startFrame: startFrame + 9_600, frameCount: min(1_024, 144_000 - startFrame)))
      }
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        writer.finish(at: CMTime(value: 153_600, timescale: 48_000)) {
          continuation.resume(with: $0)
        }
      }
      print("PCM_WRITER_STRESS completed round \(round + 1)")
    }
  }

  @Test
  func concurrentRecordingRemuxLifecycleStress() async throws {
    try await runLifecycleStress(includeRemux: true)
  }

  @Test
  func concurrentRecordingWithoutRemuxLifecycleStress() async throws {
    try await runLifecycleStress(includeRemux: false)
  }

  private func runLifecycleStress(includeRemux: Bool) async throws {
    for round in 0..<stressRounds {
      try await runSyntheticRecording(disconnect: 0, includeRemux: includeRemux)
      print("RECORDING_REMUX_STRESS completed round \(round + 1)")
    }
  }

  // 0: continuous input, 1: intermediate/tail loss, 2: no input samples at all.
  @Test(arguments: [0, 1, 2])
  func syntheticRecordingFinalizesAndRemuxesToOneMultitrackMP4(disconnect: Int) async throws {
    try await runSyntheticRecording(disconnect: disconnect, includeRemux: true)
  }

  @Test func remuxPreservesRecordedSourceClockDrift() async throws {
    try await runSyntheticRecording(disconnect: 0, includeRemux: true, sourceClockDrift: true)
  }

  @Test(arguments: [Int64(1), 20_000, 20_123])
  func remuxPreservesSubsampleInputStart(nanoseconds: Int64) async throws {
    try await runSyntheticRecording(
      disconnect: 0, includeRemux: true, subsampleSideStart: nanoseconds)
  }

  @Test func mainMixRecordingPreservesSourceClockDrift() async throws {
    try await runSyntheticRecording(disconnect: 0, includeRemux: true, mainClockDrift: true)
  }

  @Test(arguments: [Int64(1), 18_500, 20_123])
  func remuxPreservesSubsampleMainMixStart(nanoseconds: Int64) async throws {
    try await runSyntheticRecording(
      disconnect: 0, includeRemux: true, subsampleMainStart: nanoseconds)
  }

  private func runSyntheticRecording(
    disconnect: Int, includeRemux: Bool, includeSide: Bool = true,
    sourceClockDrift: Bool = false,
    mainClockDrift: Bool = false,
    subsampleSideStart: Int64? = nil,
    subsampleMainStart: Int64? = nil
  ) async throws {
    let directory = URL(
      fileURLWithPath:
        "/private/tmp/LDTXSyntheticRecordingHardTests-\(UUID().uuidString).ldtxrecord",
      isDirectory: true
    )
    let outputURL = directory.deletingPathExtension().appendingPathExtension("mp4")
    defer {
      try? FileManager.default.removeItem(at: directory)
      try? FileManager.default.removeItem(at: outputURL)
    }

    let package = try HLSByteRangeRecordingPackage(
      configuration: HLSByteRangeRecordingPackageConfiguration(
        directory: directory,
        recordID: "synthetic-test",
        targetDurationSeconds: 2,
        videoCodecs: "avc1.64002a",
        audioCodecs: "mp4a.40.2",
        bandwidth: 1_000_000,
        includesMainAudioTrack: false,
        audioTracks: includeSide
          ? [
            HLSByteRangeRecordingAudioTrack(
              id: "desk-microphone",
              displayName: "Desk Microphone",
              fileNameStem: "InputDevices/Desk%20Microphone"
            )
          ] : []
      )
    )
    let normalizer = RecordingTimelineNormalizer(origin: .zero)
    let failures = SyntheticRecordingFailures()
    let pipeline = try SessionRecordingPipeline(
      package: package,
      targetSegmentDurationSeconds: 2,
      startNumber: 1,
      timelineNormalizer: normalizer,
      failureHandler: { failures.append($0) }
    )
    let sideRecorder = try package.audioTracks["desk-microphone"].map { sideTrack in
      try AudioSideStreamRecorder(
        trackRecorder: sideTrack,
        targetSegmentDurationSeconds: 2,
        timelineNormalizer: normalizer,
        timelineTrackID: "desk-microphone"
      )
    }

    let encoded = SyntheticEncodedVideo()
    let encoder = try H264VideoEncoder(
      configuration: H264VideoEncoderConfiguration(
        width: 320,
        height: 180,
        frameRate: 30,
        bitRate: 800_000,
        keyFrameIntervalSeconds: 2
      )
    ) { encoded.append($0) }
    for index in 0..<90 {
      encoder.encode(
        pixelBuffer: try makeSyntheticPixelBuffer(width: 320, height: 180),
        presentationTime: CMTime(value: CMTimeValue(index), timescale: 30),
        duration: CMTime(value: 1, timescale: 30)
      )
    }
    try await finishSyntheticEncoder(encoder)
    for sample in try encoded.samples() {
      pipeline.appendVideo(sample)
    }

    for startFrame in stride(from: 0, to: 144_000, by: 1_024) {
      let frameCount = min(1_024, 144_000 - startFrame)
      let mainInput = try makeSyntheticAudioSample(startFrame: startFrame, frameCount: frameCount)
      if mainClockDrift || subsampleMainStart != nil {
        var timing = CMSampleTimingInfo(
          duration: CMTime(value: 1, timescale: 48_000),
          presentationTimeStamp: CMTimeAdd(
            CMTime(
              value: Int64(startFrame) * 1_000
                + (mainClockDrift ? Int64(startFrame / 1_024) * 100 : 0),
              timescale: 48_000_000),
            CMTime(value: subsampleMainStart ?? 0, timescale: 1_000_000_000)),
          decodeTimeStamp: .invalid)
        var shifted: CMSampleBuffer?
        try #require(
          CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: mainInput, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleBufferOut: &shifted) == noErr)
        pipeline.appendAudio(try #require(shifted))
      } else {
        pipeline.appendAudio(mainInput)
      }
      if includeSide && disconnect != 2
        && (disconnect == 0 || startFrame < 48_000 || (96_000..<112_640).contains(startFrame))
      {
        let input = try makeSyntheticAudioSample(
          startFrame: startFrame + 9_600,
          frameCount: frameCount,
          frequency: 660
        )
        if sourceClockDrift || subsampleSideStart != nil {
          var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTimeAdd(
              CMTime(
                value: Int64(startFrame + (subsampleSideStart != nil ? 0 : 9_600)) * 1_000
                  + (sourceClockDrift ? Int64(startFrame / 1_024) * 100 : 0), timescale: 48_000_000),
              CMTime(value: subsampleSideStart ?? 0, timescale: 1_000_000_000)),
            decodeTimeStamp: .invalid)
          var shifted: CMSampleBuffer?
          try #require(
            CMSampleBufferCreateCopyWithNewTiming(
              allocator: kCFAllocatorDefault, sampleBuffer: input, sampleTimingEntryCount: 1,
              sampleTimingArray: &timing, sampleBufferOut: &shifted) == noErr)
          sideRecorder?.append(try #require(shifted))
        } else {
          sideRecorder?.append(input)
        }
      }
    }

    await finishSyntheticPipeline(pipeline)
    let endingAt = normalizer.finish()
    if let sideRecorder {
      await withCheckedContinuation { continuation in
        sideRecorder.finish(at: endingAt) { continuation.resume() }
      }
    }
    try #require(failures.values.isEmpty)
    try package.finish()

    let fragmentedMainURL = directory.appendingPathComponent("main.fragmented.mp4")
    #expect(FileManager.default.fileExists(atPath: fragmentedMainURL.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("main.mp4").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("output-video.mp4").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("output-audio.mp4").path))
    // The recording-only control excludes asset inspection and verification too.
    guard includeRemux else { return }
    let fragmentedMainAsset = AVURLAsset(url: fragmentedMainURL)
    #expect(try await fragmentedMainAsset.loadTracks(withMediaType: .video).count == 1)
    let fragmentedAudioTracks = try await fragmentedMainAsset.loadTracks(withMediaType: .audio)
    #expect(fragmentedAudioTracks.count == 1)
    let audioTrack = try #require(fragmentedAudioTracks.first)
    let audioFormat = try #require(try await audioTrack.load(.formatDescriptions).first)
    var audioSpecificConfigSize = 0
    #expect(
      CMAudioFormatDescriptionGetMagicCookie(
        audioFormat,
        sizeOut: &audioSpecificConfigSize) != nil)
    #expect(audioSpecificConfigSize > 0)

    let recording = try RecordingPackage(contentsOf: directory)
    #expect(recording.isFinalized)
    try await RecordingPackageVerifier().verify(recording)
    try await RecordingRemuxer().remux(package: recording, to: outputURL)

    let asset = AVURLAsset(url: outputURL)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    let duration = try await asset.load(.duration)
    #expect(videoTracks.count == 1)
    #expect(audioTracks.count == 2)
    if let subsampleMainStart {
      let segments = try await audioTracks[0].load(.segments)
      let firstMedia = try #require(segments.first { !$0.isEmpty })
      let expected = CMTime(value: subsampleMainStart, timescale: 1_000_000_000)
      #expect(abs(CMTimeSubtract(firstMedia.timeMapping.target.start, expected).seconds) < 0.5e-9)
    }
    if let subsampleSideStart {
      let segments = try await audioTracks[1].load(.segments)
      let firstMedia = try #require(segments.first { !$0.isEmpty })
      let expected = CMTime(value: subsampleSideStart, timescale: 1_000_000_000)
      #expect(abs(CMTimeSubtract(firstMedia.timeMapping.target.start, expected).seconds) < 0.5e-9)
    }
    if sourceClockDrift || mainClockDrift {
      let source =
        mainClockDrift
        ? fragmentedMainAsset
        : AVURLAsset(
          url: directory.appendingPathComponent("InputDevices/Desk%20Microphone.m4a"))
      let sourceTracks = try await source.loadTracks(withMediaType: .audio)
      func times(_ asset: AVAsset, _ track: AVAssetTrack) throws -> [CMTime] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        try #require(reader.startReading())
        var result: [CMTime] = []
        while let buffer = output.copyNextSampleBuffer() {
          for index in 0..<CMSampleBufferGetNumSamples(buffer) {
            let time = try buffer.sampleTimingInfo(at: index).presentationTimeStamp
            if (0.5..<2.5).contains(time.seconds) { result.append(time) }
          }
        }
        try #require(reader.status == .completed)
        return result
      }
      let before = try times(source, #require(sourceTracks.first))
      let after = try times(asset, audioTracks[mainClockDrift ? 0 : 1])
      try #require(before.count > 50 && before.count == after.count)
      let beforeElapsed = CMTimeSubtract(try #require(before.last), try #require(before.first))
      let afterElapsed = CMTimeSubtract(try #require(after.last), try #require(after.first))
      if mainClockDrift {
        let expected = CMTime(value: Int64(before.count - 1) * 1_024_100, timescale: 48_000_000)
        #expect(abs(CMTimeSubtract(beforeElapsed, expected).seconds) <= 1e-9)
      }
      #expect(abs(CMTimeSubtract(beforeElapsed, afterElapsed).seconds) <= 1e-9)
    }
    if disconnect != 0 {
      let sideRange = try await audioTracks[1].load(.timeRange)
      #expect(CMTimeRangeGetEnd(sideRange).seconds > 2.8)
    }
    if disconnect == 2 {
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(
        track: audioTracks[1],
        outputSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsNonInterleaved: false,
        ])
      reader.add(output)
      #expect(reader.startReading())
      var frames = 0
      var peak: Float = 0
      while let sample = output.copyNextSampleBuffer() {
        let block = try #require(sample.dataBuffer)
        var values = Array(repeating: Float(0), count: CMBlockBufferGetDataLength(block) / 4)
        let status = values.withUnsafeMutableBytes {
          CMBlockBufferCopyDataBytes(
            block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        #expect(status == noErr)
        frames += sample.numSamples
        peak = max(peak, values.map { abs($0) }.max() ?? 0)
      }
      #expect(reader.status == .completed)
      #expect(frames >= 48_000 * 2)
      #expect(peak < 0.0001)
    }
    // AVAssetWriter may extend a fragmented track to the next fragment boundary under load.
    // Keep this bound tight enough to catch the historical multi-hour timestamp regression.
    #expect(duration.seconds > 2.8 && duration.seconds < 5)
    #expect(try await audioTracks[0].load(.isEnabled))
    #expect(!(try await audioTracks[1].load(.isEnabled)))
  }

  @Test func failedTrackPreventsFinalizedMarker() throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXFailedRecordingHardTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try HLSByteRangeRecordingPackage(
      configuration: HLSByteRangeRecordingPackageConfiguration(
        directory: directory,
        recordID: "failed-test",
        targetDurationSeconds: 2,
        videoCodecs: "avc1.64002a",
        audioCodecs: "mp4a.40.2",
        bandwidth: 1_000_000,
        includesMainAudioTrack: false,
        audioTracks: []
      )
    )
    try package.mainTrack.write(
      SegmentedMP4Segment(kind: .initialization, data: Data("video-init".utf8)))
    try package.mainTrack.write(
      SegmentedMP4Segment(
        kind: .media(number: 1), data: Data("video-media".utf8),
        durationSeconds: 1, earliestPresentationTimeSeconds: 0))
    package.mainTrack.markFailed(TestRecordingFailure())

    #expect(throws: TestRecordingFailure.self) {
      try package.finish()
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(
          RecordingPackage.finalizedMarkerFileName
        ).path
      )
    )
  }

  @Test func incompleteMainProgramPreventsFinalization() async throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXIncompleteRecordingHardTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try HLSByteRangeRecordingPackage(
      configuration: HLSByteRangeRecordingPackageConfiguration(
        directory: directory,
        recordID: "incomplete-test",
        targetDurationSeconds: 2,
        videoCodecs: "avc1.64002a",
        audioCodecs: "mp4a.40.2",
        bandwidth: 1_000_000,
        includesMainAudioTrack: false,
        audioTracks: []
      )
    )
    let failures = SyntheticRecordingFailures()
    let pipeline = try SessionRecordingPipeline(
      package: package,
      targetSegmentDurationSeconds: 2,
      startNumber: 1,
      timelineNormalizer: RecordingTimelineNormalizer(origin: .zero),
      failureHandler: { failures.append($0) }
    )

    await finishSyntheticPipeline(pipeline)

    #expect(failures.values.count == 1)
    #expect(
      failures.values.first?.localizedDescription
        == SessionRecordingPipelineError.incompleteMainProgram.localizedDescription)
    #expect(throws: SessionRecordingPipelineError.self) {
      try package.finish()
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(
          RecordingPackage.finalizedMarkerFileName
        ).path
      )
    )
  }

  @Test func audioBufferedBeforeVideoProducesAMuxedMainProgram() async throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXAudioFirstRecordingHardTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try makeSyntheticRecordingPackage(directory: directory, recordID: "audio-first")
    let failures = SyntheticRecordingFailures()
    let pipeline = try SessionRecordingPipeline(
      package: package,
      targetSegmentDurationSeconds: 2,
      startNumber: 1,
      timelineNormalizer: RecordingTimelineNormalizer(origin: .zero),
      failureHandler: { failures.append($0) }
    )

    for startFrame in stride(from: 0, to: 48_000, by: 1_024) {
      pipeline.appendAudio(
        try makeSyntheticAudioSample(
          startFrame: startFrame,
          frameCount: min(1_024, 48_000 - startFrame)
        ))
    }
    for sample in try await makeSyntheticVideoSamples(frameCount: 30) {
      pipeline.appendVideo(sample)
    }

    await finishSyntheticPipeline(pipeline)
    try #require(failures.values.isEmpty)
    try package.finish()

    let asset = AVURLAsset(url: directory.appendingPathComponent("main.fragmented.mp4"))
    #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
  }

  @MainActor @Test func embeddedMainMixIgnoresTheVideoManifestOffset() async throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXDelayedMainMixHardTests-\(UUID().uuidString).ldtxrecord",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try makeSyntheticRecordingPackage(directory: directory, recordID: "delayed-mix")
    let failures = SyntheticRecordingFailures()
    let pipeline = try SessionRecordingPipeline(
      package: package,
      targetSegmentDurationSeconds: 2,
      startNumber: 1,
      timelineNormalizer: RecordingTimelineNormalizer(origin: .zero),
      failureHandler: { failures.append($0) }
    )
    for sample in try await makeSyntheticVideoSamples(frameCount: 60) {
      pipeline.appendVideo(sample)
    }
    for startFrame in stride(from: 9_600, to: 57_600, by: 1_024) {
      pipeline.appendAudio(
        try makeSyntheticAudioSample(
          startFrame: startFrame,
          frameCount: min(1_024, 57_600 - startFrame)
        ))
    }

    await finishSyntheticPipeline(pipeline)
    try #require(failures.values.isEmpty)
    try package.finish()
    let shiftedVideoManifest = """
      <MPD><Period start="PT5S"><AdaptationSet><Representation>
      <SegmentList timescale="1" presentationTimeOffset="0">
      <Initialization sourceURL="main.fragmented.mp4"/>
      <SegmentTimeline><S t="0" d="1"/></SegmentTimeline>
      </SegmentList></Representation></AdaptationSet></Period></MPD>
      """
    try Data(shiftedVideoManifest.utf8).write(
      to: directory.appendingPathComponent(RecordingPackage.manifestFileName))

    let recording = try RecordingPackage(contentsOf: directory)
    let sourceAsset = AVURLAsset(url: recording.mainMediaURL)
    let sourceAudio = try #require(
      try await sourceAsset.loadTracks(withMediaType: .audio).first)
    let nativeStart = try await sourceAudio.load(.timeRange).start
    let composition = try await RecordingCompositionLoader().load(package: recording)
    let compositionAudio = try #require(
      composition.tracks(withMediaType: .audio).first)
    let compositionStart = try #require(
      compositionAudio.segments.first(where: { !$0.isEmpty })
    ).timeMapping.target.start

    #expect(abs(compositionStart.seconds - nativeStart.seconds) < 0.001)
    let compositionVideo = try #require(
      composition.tracks(withMediaType: .video).first)
    let compositionVideoStart = try #require(
      compositionVideo.segments.first(where: { !$0.isEmpty })
    ).timeMapping.target.start
    #expect(abs(compositionVideoStart.seconds - 5) < 0.001)
  }

  @Test func videoWithoutMainMixPreventsFinalization() async throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXVideoOnlyRecordingHardTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try makeSyntheticRecordingPackage(directory: directory, recordID: "video-only")
    let failures = SyntheticRecordingFailures()
    let pipeline = try SessionRecordingPipeline(
      package: package,
      targetSegmentDurationSeconds: 2,
      startNumber: 1,
      timelineNormalizer: RecordingTimelineNormalizer(origin: .zero),
      failureHandler: { failures.append($0) }
    )
    for sample in try await makeSyntheticVideoSamples(frameCount: 30) {
      pipeline.appendVideo(sample)
    }

    await finishSyntheticPipeline(pipeline)

    #expect(failures.values.count == 1)
    #expect(throws: SessionRecordingPipelineError.self) { try package.finish() }
    #expect(!hasFinalizedMarker(in: directory))
  }

  @Test func videoPendingMainMixIsBoundedByDuration() async throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXPendingMainMixHardTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try makeSyntheticRecordingPackage(directory: directory, recordID: "pending-mix")
    let failures = SyntheticRecordingFailures()
    let pipeline = try SessionRecordingPipeline(
      package: package,
      targetSegmentDurationSeconds: 2,
      startNumber: 1,
      timelineNormalizer: RecordingTimelineNormalizer(origin: .zero),
      failureHandler: { failures.append($0) }
    )
    let samples = try await makeSyntheticVideoSamples(frameCount: 2)
    pipeline.appendVideo(try #require(samples.first))
    pipeline.appendVideo(
      try retimeSyntheticSample(try #require(samples.last), presentationTime: 31))

    #expect(failures.values.count == 1)
    guard let error = failures.values.first as? SessionRecordingPipelineError,
      case .pendingMainMixExceededLimit = error
    else {
      Issue.record("Expected the pending Main Mix buffer limit failure")
      return
    }
    await finishSyntheticPipeline(pipeline)
    #expect(throws: SessionRecordingPipelineError.self) { try package.finish() }
    #expect(!hasFinalizedMarker(in: directory))
  }

  @Test func muxedBacklogIsBoundedWhenMainMixStallsAfterStartup() async throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXMuxedBacklogHardTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try makeSyntheticRecordingPackage(directory: directory, recordID: "mux-stall")
    let failures = SyntheticRecordingFailures()
    let pipeline = try SessionRecordingPipeline(
      package: package,
      targetSegmentDurationSeconds: 2,
      startNumber: 1,
      timelineNormalizer: RecordingTimelineNormalizer(origin: .zero),
      failureHandler: { failures.append($0) }
    )
    let samples = try await makeSyntheticVideoSamples(frameCount: 3)
    pipeline.appendVideo(try #require(samples.first))
    pipeline.appendAudio(try makeSyntheticAudioSample(startFrame: 0, frameCount: 1_024))
    pipeline.appendVideo(
      try retimeSyntheticSample(samples[1], presentationTime: 31))
    pipeline.appendVideo(
      try retimeSyntheticSample(samples[2], presentationTime: 62))
    await finishSyntheticPipeline(pipeline)

    #expect(failures.values.count == 1)
    guard let error = failures.values.first as? MuxedPassthroughSegmentedMP4WriterError,
      case .pendingSamplesExceededLimit = error
    else {
      Issue.record("Expected the muxed pending media limit failure: \(failures.values)")
      return
    }
    #expect(throws: Error.self) { try package.finish() }
    #expect(!hasFinalizedMarker(in: directory))
  }

  @Test func muxedBacklogIsBoundedWhenVideoStallsAfterStartup() async throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXMuxedAudioBacklogHardTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try makeSyntheticRecordingPackage(directory: directory, recordID: "video-stall")
    let failures = SyntheticRecordingFailures()
    let pipeline = try SessionRecordingPipeline(
      package: package,
      targetSegmentDurationSeconds: 2,
      startNumber: 1,
      timelineNormalizer: RecordingTimelineNormalizer(origin: .zero),
      failureHandler: { failures.append($0) }
    )
    pipeline.appendVideo(try #require(try await makeSyntheticVideoSamples(frameCount: 1).first))
    pipeline.appendAudio(try makeSyntheticAudioSample(startFrame: 0, frameCount: 1_024))
    for startFrame in stride(from: 1_024, to: 32 * 48_000, by: 1_024) {
      pipeline.appendAudio(
        try makeSyntheticAudioSample(startFrame: startFrame, frameCount: 1_024))
    }
    await finishSyntheticPipeline(pipeline)

    #expect(failures.values.count == 1)
    guard let error = failures.values.first as? MuxedPassthroughSegmentedMP4WriterError,
      case .pendingSamplesExceededLimit = error
    else {
      Issue.record("Expected the muxed pending media limit failure: \(failures.values)")
      return
    }
    #expect(throws: Error.self) { try package.finish() }
    #expect(!hasFinalizedMarker(in: directory))
  }

  @Test func cutWithOnlyCachedMainMixFormatPreventsFinalization() async throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXCutWithoutMainMixHardTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try makeSyntheticRecordingPackage(directory: directory, recordID: "cut-no-mix")
    let failures = SyntheticRecordingFailures()
    let pipeline = try SessionRecordingPipeline(
      package: package,
      targetSegmentDurationSeconds: 2,
      startNumber: 1,
      timelineNormalizer: RecordingTimelineNormalizer(origin: .zero),
      failureHandler: { failures.append($0) }
    )
    let firstVideo = try #require(
      try await makeSyntheticVideoSamples(frameCount: 1).first)
    let cachedMainMix = try makeSyntheticAudioSample(startFrame: 0, frameCount: 1_024)
    let formatDescription = try #require(cachedMainMix.formatDescription)

    try pipeline.appendFirstVideo(
      firstVideo,
      mainAudioFormatDescription: formatDescription)
    await finishSyntheticPipeline(pipeline)

    #expect(failures.values.count == 1)
    #expect(throws: SessionRecordingPipelineError.self) { try package.finish() }
    #expect(!hasFinalizedMarker(in: directory))
  }

  @Test func mainMixWithoutVideoPreventsFinalization() async throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXAudioOnlyRecordingHardTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try makeSyntheticRecordingPackage(directory: directory, recordID: "audio-only")
    let failures = SyntheticRecordingFailures()
    let pipeline = try SessionRecordingPipeline(
      package: package,
      targetSegmentDurationSeconds: 2,
      startNumber: 1,
      timelineNormalizer: RecordingTimelineNormalizer(origin: .zero),
      failureHandler: { failures.append($0) }
    )
    pipeline.appendAudio(try makeSyntheticAudioSample(startFrame: 0, frameCount: 1_024))

    await finishSyntheticPipeline(pipeline)

    #expect(failures.values.count == 1)
    #expect(throws: SessionRecordingPipelineError.self) { try package.finish() }
    #expect(!hasFinalizedMarker(in: directory))
  }

  @Test func repeatedAudioEncoderFailureIsReportedOnlyOnce() async throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXRepeatedFailureHardTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try makeSyntheticRecordingPackage(
      directory: directory,
      recordID: "repeated-failure"
    )
    let failures = SyntheticRecordingFailures()
    let pipeline = try SessionRecordingPipeline(
      package: package,
      targetSegmentDurationSeconds: 2,
      startNumber: 1,
      timelineNormalizer: RecordingTimelineNormalizer(origin: .zero),
      failureHandler: { failures.append($0) }
    )
    let invalidAudioSample = try #require(
      try await makeSyntheticVideoSamples(frameCount: 1).first)

    pipeline.appendAudio(invalidAudioSample)
    pipeline.appendAudio(invalidAudioSample)
    await finishSyntheticPipeline(pipeline)

    #expect(failures.values.count == 1)
    #expect(throws: Error.self) { try package.finish() }
    #expect(!hasFinalizedMarker(in: directory))
  }

  @Test func finalizedMarkerIsWrittenOnlyAfterTheFinalizationHookSucceeds() throws {
    let successfulDirectory = URL(
      fileURLWithPath: "/private/tmp/LDTXFinalizationOrderHardTests-\(UUID().uuidString)",
      isDirectory: true
    )
    let failedDirectory = URL(
      fileURLWithPath: "/private/tmp/LDTXFinalizationFailureHardTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer {
      try? FileManager.default.removeItem(at: successfulDirectory)
      try? FileManager.default.removeItem(at: failedDirectory)
    }
    let successfulPackage = try makeCompleteSyntheticPackage(directory: successfulDirectory)
    var markerExistedDuringHook = true

    try successfulPackage.finish {
      markerExistedDuringHook = hasFinalizedMarker(in: successfulDirectory)
    }

    #expect(!markerExistedDuringHook)
    #expect(hasFinalizedMarker(in: successfulDirectory))

    let failedPackage = try makeCompleteSyntheticPackage(directory: failedDirectory)
    #expect(throws: TestRecordingFailure.self) {
      try failedPackage.finish { throw TestRecordingFailure() }
    }
    #expect(!hasFinalizedMarker(in: failedDirectory))
  }

  @Test func recordingPackageUsesMuxedFragmentedMainProgram() throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXSeparatedRecordingHardTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let package = try HLSByteRangeRecordingPackage(
      configuration: HLSByteRangeRecordingPackageConfiguration(
        directory: directory,
        recordID: "test",
        targetDurationSeconds: 2,
        videoCodecs: "avc1.64002a",
        audioCodecs: "mp4a.40.2",
        bandwidth: 1_000_000,
        includesMainAudioTrack: false,
        audioTracks: [
          HLSByteRangeRecordingAudioTrack(
            id: "side",
            displayName: "Desk / Microphone",
            fileNameStem: "InputDevices/Desk%20%2F%20Microphone"
          )
        ]
      )
    )
    try package.mainTrack.write(
      SegmentedMP4Segment(kind: .initialization, data: Data("video-init".utf8)))
    try package.mainTrack.write(
      SegmentedMP4Segment(
        kind: .media(number: 1), data: Data("video-media".utf8),
        durationSeconds: 2, earliestPresentationTimeSeconds: 100))
    try package.audioTracks["side"]?.write(
      SegmentedMP4Segment(kind: .initialization, data: Data("side-init".utf8)))
    try package.audioTracks["side"]?.write(
      SegmentedMP4Segment(
        kind: .media(number: 1), data: Data("side-media".utf8),
        durationSeconds: 1.7, earliestPresentationTimeSeconds: 100.3))
    try package.finish()

    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(
          RecordingPackage.finalizedMarkerFileName
        ).path
      )
    )

    let readme = try String(
      contentsOf: directory.appendingPathComponent(RecordingPackage.readmeFileName),
      encoding: .utf8
    )
    #expect(readme == RecordingPackage.remuxReadme)

    let infoData = try Data(contentsOf: directory.appendingPathComponent("Info.plist"))
    let info = try #require(
      PropertyListSerialization.propertyList(from: infoData, options: 0, format: nil)
        as? [String: Any]
    )
    #expect(info["CFBundleIdentifier"] as? String == "tokyo.kaito.ldtx.recording")
    #expect(info["CFBundleInfoDictionaryVersion"] as? String == "6.0")
    #expect(info["CFBundleName"] as? String == "test")
    #expect(info["CFBundlePackageType"] as? String == "BNDL")
    #expect(info["LDTXRecordingFormatVersion"] as? Int == 2)
    #expect(info["LDTXRecordingIdentifier"] as? String == "test")
    #expect(info["LDTXRecordingManifestFile"] as? String == "manifest.mpd")
    #expect(info["LDTXRecordingMasterPlaylist"] == nil)
    #expect(info["LDTXRecordingMainPlaylist"] == nil)
    #expect(info["LDTXRecordingMainMediaFile"] as? String == "main.fragmented.mp4")
    let audioTracks = try #require(info["LDTXRecordingAudioTracks"] as? [[String: String]])
    #expect(
      audioTracks == [
        [
          "Identifier": "side",
          "Name": "Desk / Microphone",
          "MediaFile": "InputDevices/Desk%20%2F%20Microphone.m4a",
        ]
      ])

    let manifest = try String(
      contentsOf: directory.appendingPathComponent("manifest.mpd"),
      encoding: .utf8
    )
    #expect(manifest.contains("type=\"static\""))
    #expect(manifest.contains("presentationTimeOffset=\"100000000000\""))
    #expect(manifest.contains("<S t=\"100000000000\" d=\"2000000000\"/>"))
    #expect(manifest.contains("<ContentComponent id=\"1\" contentType=\"video\"/>"))
    #expect(manifest.contains("<ContentComponent id=\"2\" contentType=\"audio\"/>"))
    #expect(manifest.contains("codecs=\"avc1.64002a,mp4a.40.2\""))
    #expect(manifest.contains("<Label>Desk / Microphone</Label>"))
    #expect(manifest.contains("media=\"main.fragmented.mp4\""))
    #expect(manifest.contains("media=\"InputDevices/Desk%2520%252F%2520Microphone.m4a\""))
  }

  @Test func writesInitializationBeforeMediaAndDrainsBeforeFinishReturns() async throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXAudioSideStreamPipelineHardTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let recorder = try HLSByteRangeTrackRecorder(
      directory: directory,
      mediaFileName: "InputDevices/Desk%20Microphone.mp4"
    )
    let pipeline = AudioSideStreamSegmentPipeline()
    pipeline.start { segment in
      try recorder.write(segment)
    }

    pipeline.yield(
      SegmentedMP4Segment(
        kind: .initialization,
        data: Data("initialization".utf8)
      ))
    pipeline.yield(
      SegmentedMP4Segment(
        kind: .media(number: 1),
        data: Data("media".utf8),
        durationSeconds: 1,
        earliestPresentationTimeSeconds: 42
      ))
    await withCheckedContinuation { continuation in
      pipeline.drain { continuation.resume() }
    }
    await withCheckedContinuation { continuation in
      pipeline.finish { continuation.resume() }
    }
    recorder.finish()

    let media = try Data(
      contentsOf: directory.appendingPathComponent("InputDevices/Desk%20Microphone.mp4")
    )
    #expect(media == Data("initializationmedia".utf8))

    let snapshot = recorder.snapshot()
    #expect(snapshot.initialization == MP4ByteRange(offset: 0, length: 14))
    #expect(snapshot.segments.count == 1)
    #expect(snapshot.segments.first?.range == MP4ByteRange(offset: 14, length: 5))
    #expect(snapshot.segments.first?.durationSeconds == 1)
    #expect(snapshot.segments.first?.earliestPresentationTimeSeconds == 42)
  }

  @Test func snapshotUsesThePreWriterPresentationStart() throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXTrackTimelineHardTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try HLSByteRangeTrackRecorder(
      directory: directory,
      mediaFileName: "audio.mp4"
    )
    recorder.notePresentationStart(CMTime(seconds: 0.625, preferredTimescale: 48_000))
    try recorder.write(
      SegmentedMP4Segment(
        kind: .media(number: 1),
        data: Data("media".utf8),
        durationSeconds: 2,
        earliestPresentationTimeSeconds: 0
      ))

    let snapshot = recorder.snapshot()

    #expect(snapshot.segments.first?.earliestPresentationTimeSeconds == 0.625)
  }

  @Test func performIsSerializedWithSegmentWrites() async throws {
    let eventLog = AudioSideStreamPipelineEventLog()
    let pipeline = AudioSideStreamSegmentPipeline()
    pipeline.start { segment in
      guard case .media(let number) = segment.kind else { return }
      eventLog.append("segment-\(number)")
    }

    pipeline.yield(
      SegmentedMP4Segment(
        kind: .media(number: 1),
        data: Data(),
        durationSeconds: 1
      ))
    try pipeline.perform {
      eventLog.append("rotate")
    }
    pipeline.yield(
      SegmentedMP4Segment(
        kind: .media(number: 2),
        data: Data(),
        durationSeconds: 1
      ))
    await withCheckedContinuation { continuation in
      pipeline.finish { continuation.resume() }
    }

    let events = eventLog.snapshot()
    #expect(events == ["segment-1", "rotate", "segment-2"])
  }
}

private struct TestRecordingFailure: Error {}

private enum SyntheticRecordingTestError: Error {
  case coreMedia(OSStatus)
  case missingObject
}

private final class SyntheticEncodedVideo: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Result<CMSampleBuffer, any Error>] = []

  func append(_ result: Result<CMSampleBuffer, any Error>) {
    lock.withLock { results.append(result) }
  }

  func samples() throws -> [CMSampleBuffer] {
    try lock.withLock { try results.map { try $0.get() } }
  }
}

private final class SyntheticRecordingFailures: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [any Error] = []

  var values: [any Error] { lock.withLock { storage } }

  func append(_ error: any Error) {
    lock.withLock { storage.append(error) }
  }
}

private func makeSyntheticRecordingPackage(
  directory: URL,
  recordID: String
) throws -> HLSByteRangeRecordingPackage {
  try HLSByteRangeRecordingPackage(
    configuration: HLSByteRangeRecordingPackageConfiguration(
      directory: directory,
      recordID: recordID,
      targetDurationSeconds: 2,
      videoCodecs: "avc1.64002a",
      audioCodecs: "mp4a.40.2",
      bandwidth: 1_000_000,
      includesMainAudioTrack: false,
      audioTracks: []
    )
  )
}

private func makeCompleteSyntheticPackage(
  directory: URL
) throws -> HLSByteRangeRecordingPackage {
  let package = try makeSyntheticRecordingPackage(directory: directory, recordID: "finalization")
  try package.mainTrack.write(
    SegmentedMP4Segment(kind: .initialization, data: Data("main-init".utf8)))
  try package.mainTrack.write(
    SegmentedMP4Segment(
      kind: .media(number: 1),
      data: Data("main-media".utf8),
      durationSeconds: 1,
      earliestPresentationTimeSeconds: 0
    ))
  return package
}

private func makeSyntheticVideoSamples(frameCount: Int) async throws -> [CMSampleBuffer] {
  let encoded = SyntheticEncodedVideo()
  let encoder = try H264VideoEncoder(
    configuration: H264VideoEncoderConfiguration(
      width: 320,
      height: 180,
      frameRate: 30,
      bitRate: 800_000,
      keyFrameIntervalSeconds: 2
    )
  ) { encoded.append($0) }
  for index in 0..<frameCount {
    encoder.encode(
      pixelBuffer: try makeSyntheticPixelBuffer(width: 320, height: 180),
      presentationTime: CMTime(value: CMTimeValue(index), timescale: 30),
      duration: CMTime(value: 1, timescale: 30)
    )
  }
  try await finishSyntheticEncoder(encoder)
  return try encoded.samples()
}

private func retimeSyntheticSample(
  _ sampleBuffer: CMSampleBuffer,
  presentationTime seconds: Double
) throws -> CMSampleBuffer {
  var timing = CMSampleTimingInfo()
  var status = CMSampleBufferGetSampleTimingInfo(
    sampleBuffer,
    at: 0,
    timingInfoOut: &timing)
  guard status == noErr else { throw SyntheticRecordingTestError.coreMedia(status) }
  timing.presentationTimeStamp = CMTime(seconds: seconds, preferredTimescale: 600)
  timing.decodeTimeStamp = .invalid
  var copy: CMSampleBuffer?
  status = CMSampleBufferCreateCopyWithNewTiming(
    allocator: kCFAllocatorDefault,
    sampleBuffer: sampleBuffer,
    sampleTimingEntryCount: 1,
    sampleTimingArray: &timing,
    sampleBufferOut: &copy)
  guard status == noErr, let copy else {
    throw SyntheticRecordingTestError.coreMedia(status)
  }
  return copy
}

private func hasFinalizedMarker(in directory: URL) -> Bool {
  FileManager.default.fileExists(
    atPath: directory.appendingPathComponent(RecordingPackage.finalizedMarkerFileName).path
  )
}

private func finishSyntheticEncoder(_ encoder: H264VideoEncoder) async throws {
  try await withCheckedThrowingContinuation { continuation in
    encoder.finish { continuation.resume(with: $0) }
  }
}

private func finishSyntheticPipeline(_ pipeline: SessionRecordingPipeline) async {
  await withCheckedContinuation { continuation in
    pipeline.finish { continuation.resume() }
  }
}

private func finishSyntheticSideRecorder(_ recorder: AudioSideStreamRecorder) async {
  await withCheckedContinuation { continuation in
    recorder.finish { continuation.resume() }
  }
}

private func makeSyntheticPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
  var pixelBuffer: CVPixelBuffer?
  let status = CVPixelBufferCreate(
    kCFAllocatorDefault,
    width,
    height,
    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
    &pixelBuffer
  )
  guard status == kCVReturnSuccess, let pixelBuffer else {
    throw SyntheticRecordingTestError.missingObject
  }
  return pixelBuffer
}

private func makeSyntheticAudioSample(
  startFrame: Int,
  frameCount: Int,
  frequency: Double = 440
) throws -> CMSampleBuffer {
  let sampleRate = 48_000
  let channelCount = 2
  var data = Data(count: frameCount * channelCount * MemoryLayout<Float32>.size)
  data.withUnsafeMutableBytes { bytes in
    let samples = bytes.bindMemory(to: Float32.self)
    for frame in 0..<frameCount {
      let value = Float32(
        sin(2 * Double.pi * frequency * Double(startFrame + frame) / Double(sampleRate)) * 0.2
      )
      samples[frame * channelCount] = value
      samples[frame * channelCount + 1] = value
    }
  }

  var blockBuffer: CMBlockBuffer?
  var status = CMBlockBufferCreateWithMemoryBlock(
    allocator: kCFAllocatorDefault,
    memoryBlock: nil,
    blockLength: data.count,
    blockAllocator: nil,
    customBlockSource: nil,
    offsetToData: 0,
    dataLength: data.count,
    flags: 0,
    blockBufferOut: &blockBuffer
  )
  guard status == kCMBlockBufferNoErr, let blockBuffer else {
    throw SyntheticRecordingTestError.coreMedia(status)
  }
  status = data.withUnsafeBytes { bytes in
    CMBlockBufferReplaceDataBytes(
      with: bytes.baseAddress!,
      blockBuffer: blockBuffer,
      offsetIntoDestination: 0,
      dataLength: data.count
    )
  }
  guard status == kCMBlockBufferNoErr else {
    throw SyntheticRecordingTestError.coreMedia(status)
  }

  var stream = AudioStreamBasicDescription(
    mSampleRate: Double(sampleRate),
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: UInt32(channelCount * MemoryLayout<Float32>.size),
    mFramesPerPacket: 1,
    mBytesPerFrame: UInt32(channelCount * MemoryLayout<Float32>.size),
    mChannelsPerFrame: UInt32(channelCount),
    mBitsPerChannel: 32,
    mReserved: 0
  )
  var format: CMAudioFormatDescription?
  status = CMAudioFormatDescriptionCreate(
    allocator: kCFAllocatorDefault,
    asbd: &stream,
    layoutSize: 0,
    layout: nil,
    magicCookieSize: 0,
    magicCookie: nil,
    extensions: nil,
    formatDescriptionOut: &format
  )
  guard status == noErr, let format else {
    throw SyntheticRecordingTestError.coreMedia(status)
  }
  var timing = CMSampleTimingInfo(
    duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
    presentationTimeStamp: CMTime(
      value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate)),
    decodeTimeStamp: .invalid
  )
  var sampleBuffer: CMSampleBuffer?
  status = CMSampleBufferCreateReady(
    allocator: kCFAllocatorDefault,
    dataBuffer: blockBuffer,
    formatDescription: format,
    sampleCount: frameCount,
    sampleTimingEntryCount: 1,
    sampleTimingArray: &timing,
    sampleSizeEntryCount: 0,
    sampleSizeArray: nil,
    sampleBufferOut: &sampleBuffer
  )
  guard status == noErr, let sampleBuffer else {
    throw SyntheticRecordingTestError.coreMedia(status)
  }
  return sampleBuffer
}

private final class AudioSideStreamPipelineEventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [String] = []

  func append(_ event: String) {
    lock.withLock { events.append(event) }
  }

  func snapshot() -> [String] {
    lock.withLock { events }
  }
}
