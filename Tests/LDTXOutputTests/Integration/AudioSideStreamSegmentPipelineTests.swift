// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import LDTXCorelibs
@testable import LDTXMP4
@testable import LDTXProgramRuntime
import LDTXRecording
@testable import LDTXWorkspaceAppletService
import Synchronization
import Testing

private struct RecordingMetadata: Decodable {
  var bundleIdentifier: String
  var infoDictionaryVersion: String
  var bundleName: String
  var packageType: String
  var formatVersion: Int
  var identifier: String
  var manifestFile: String
  var masterPlaylist: String?
  var mainPlaylist: String?
  var mainMediaFile: String
  var audioTracks: [[String: String]]

  enum CodingKeys: String, CodingKey {
    case bundleIdentifier = "CFBundleIdentifier"
    case infoDictionaryVersion = "CFBundleInfoDictionaryVersion"
    case bundleName = "CFBundleName"
    case packageType = "CFBundlePackageType"
    case formatVersion = "LDTXRecordingFormatVersion"
    case identifier = "LDTXRecordingIdentifier"
    case manifestFile = "LDTXRecordingManifestFile"
    case masterPlaylist = "LDTXRecordingMasterPlaylist"
    case mainPlaylist = "LDTXRecordingMainPlaylist"
    case mainMediaFile = "LDTXRecordingMainMediaFile"
    case audioTracks = "LDTXRecordingAudioTracks"
  }
}

extension OutputTestSuite.AVAssetWriterLifecycleIntegrationTestSuite {
  @Suite
  struct AudioSideStreamSegmentPipelineIntegrationTestSuite {
    // 0: continuous input, 1: intermediate/tail loss, 2: no input samples at all.
    @Test(
      "LUB-1060: Synthetic recording finalizes and remuxes to one multitrack MP4",
      arguments: [0, 1, 2])
    func syntheticRecordingFinalizesAndRemuxesToOneMultitrackMP4(disconnect: Int) async throws {
      try await runSyntheticRecording(disconnect: disconnect)
    }

    @Test("LUB-1060: Remux preserves recorded source clock drift")
    func remuxPreservesRecordedSourceClockDrift() async throws {
      try await runSyntheticRecording(disconnect: 0, sourceClockDrift: true)
    }

    @Test("LUB-1060: Remux preserves subsample input start", arguments: [Int64(1), 20_000, 20_123])
    func remuxPreservesSubsampleInputStart(nanoseconds: Int64) async throws {
      try await runSyntheticRecording(
        disconnect: 0, subsampleSideStart: nanoseconds)
    }

    @Test("LUB-1060: Main mix recording preserves source clock drift")
    func mainMixRecordingPreservesSourceClockDrift() async throws {
      try await runSyntheticRecording(disconnect: 0, mainClockDrift: true)
    }

    @Test(
      "LUB-1060: Remux preserves subsample main mix start", arguments: [Int64(1), 18_500, 20_123])
    func remuxPreservesSubsampleMainMixStart(nanoseconds: Int64) async throws {
      try await runSyntheticRecording(
        disconnect: 0, subsampleMainStart: nanoseconds)
    }

    private func runSyntheticRecording(
      disconnect: Int,
      sourceClockDrift: Bool = false,
      mainClockDrift: Bool = false,
      subsampleSideStart: Int64? = nil,
      subsampleMainStart: Int64? = nil
    ) async throws {
      let directory = URL(
        fileURLWithPath:
          "/private/tmp/LDTXSyntheticRecordingIntegrationTestSuite-\(UUID().uuidString).ldtxrecord",
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
          audioTracks: [
            HLSByteRangeRecordingAudioTrack(
              id: "desk-microphone",
              displayName: "Desk Microphone",
              fileNameStem: "InputDevices/Desk%20Microphone"
            )
          ]
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
          timelineTrackID: "desk-microphone", failureHandler: { failures.append($0) }
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
        if disconnect != 2
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
                    + (sourceClockDrift ? Int64(startFrame / 1_024) * 100 : 0),
                  timescale: 48_000_000),
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
      let fragmentedMainAsset = AVURLAsset(url: fragmentedMainURL)
      #expect(try await fragmentedMainAsset.loadTracks(withMediaType: .video).count == 1)
      let fragmentedAudioTracks = try await fragmentedMainAsset.loadTracks(withMediaType: .audio)
      #expect(fragmentedAudioTracks.count == 1)
      try assertSyntheticRecordingTimingClocks(Data(contentsOf: fragmentedMainURL))
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
          #expect(abs(CMTimeSubtract(beforeElapsed, expected).seconds) <= 1.0 / 48_000)
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

    @Test("LUB-1060: Failed track prevents finalized marker")
    func failedTrackPreventsFinalizedMarker() throws {
      let directory = URL(
        fileURLWithPath:
          "/private/tmp/LDTXFailedRecordingIntegrationTestSuite-\(UUID().uuidString)",
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

    @Test("LUB-1060: Incomplete main program prevents finalization")
    func incompleteMainProgramPreventsFinalization() async throws {
      let directory = URL(
        fileURLWithPath:
          "/private/tmp/LDTXIncompleteRecordingIntegrationTestSuite-\(UUID().uuidString)",
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

    @Test("LUB-1060: Audio buffered before video produces a muxed main program")
    func audioBufferedBeforeVideoProducesAMuxedMainProgram() async throws {
      let directory = URL(
        fileURLWithPath:
          "/private/tmp/LDTXAudioFirstRecordingIntegrationTestSuite-\(UUID().uuidString)",
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

    @MainActor @Test("LUB-1060: Embedded main mix ignores the video manifest offset")
    func embeddedMainMixIgnoresTheVideoManifestOffset() async throws {
      let directory = URL(
        fileURLWithPath:
          "/private/tmp/LDTXDelayedMainMixIntegrationTestSuite-\(UUID().uuidString).ldtxrecord",
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

    @Test("LUB-1060: Video without main mix prevents finalization")
    func videoWithoutMainMixPreventsFinalization() async throws {
      let directory = URL(
        fileURLWithPath:
          "/private/tmp/LDTXVideoOnlyRecordingIntegrationTestSuite-\(UUID().uuidString)",
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

    @Test("LUB-1060: Video pending main mix is bounded by duration")
    func videoPendingMainMixIsBoundedByDuration() async throws {
      let directory = URL(
        fileURLWithPath: "/private/tmp/LDTXPendingMainMixIntegrationTestSuite-\(UUID().uuidString)",
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

    @Test("LUB-1060: Muxed backlog is bounded when main mix stalls after startup")
    func muxedBacklogIsBoundedWhenMainMixStallsAfterStartup() async throws {
      let directory = URL(
        fileURLWithPath: "/private/tmp/LDTXMuxedBacklogIntegrationTestSuite-\(UUID().uuidString)",
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

    @Test("LUB-1060: Muxed backlog is bounded when video stalls after startup")
    func muxedBacklogIsBoundedWhenVideoStallsAfterStartup() async throws {
      let directory = URL(
        fileURLWithPath:
          "/private/tmp/LDTXMuxedAudioBacklogIntegrationTestSuite-\(UUID().uuidString)",
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

    @Test("LUB-1060: Cut with only cached main mix format prevents finalization")
    func cutWithOnlyCachedMainMixFormatPreventsFinalization() async throws {
      let directory = URL(
        fileURLWithPath:
          "/private/tmp/LDTXCutWithoutMainMixIntegrationTestSuite-\(UUID().uuidString)",
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

    @Test("LUB-1060: Main mix without video prevents finalization")
    func mainMixWithoutVideoPreventsFinalization() async throws {
      let directory = URL(
        fileURLWithPath:
          "/private/tmp/LDTXAudioOnlyRecordingIntegrationTestSuite-\(UUID().uuidString)",
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

    @Test("LUB-1060: Repeated audio encoder failure is reported only once")
    func repeatedAudioEncoderFailureIsReportedOnlyOnce() async throws {
      let directory = URL(
        fileURLWithPath:
          "/private/tmp/LDTXRepeatedFailureIntegrationTestSuite-\(UUID().uuidString)",
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

    @Test("LUB-1060: Finalized marker is written only after the finalization hook succeeds")
    func finalizedMarkerIsWrittenOnlyAfterTheFinalizationHookSucceeds() throws {
      let successfulDirectory = URL(
        fileURLWithPath:
          "/private/tmp/LDTXFinalizationOrderIntegrationTestSuite-\(UUID().uuidString)",
        isDirectory: true
      )
      let failedDirectory = URL(
        fileURLWithPath:
          "/private/tmp/LDTXFinalizationFailureIntegrationTestSuite-\(UUID().uuidString)",
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

    @Test("LUB-1060: Recording package uses muxed fragmented main program")
    func recordingPackageUsesMuxedFragmentedMainProgram() throws {
      let directory = URL(
        fileURLWithPath:
          "/private/tmp/LDTXSeparatedRecordingIntegrationTestSuite-\(UUID().uuidString)",
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
      let info = try PropertyListDecoder().decode(RecordingMetadata.self, from: infoData)
      #expect(info.bundleIdentifier == "tokyo.kaito.ldtx.record")
      #expect(info.infoDictionaryVersion == "6.0")
      #expect(info.bundleName == "test")
      #expect(info.packageType == "BNDL")
      #expect(info.formatVersion == 2)
      #expect(info.identifier == "test")
      #expect(info.manifestFile == "manifest.mpd")
      #expect(info.masterPlaylist == nil)
      #expect(info.mainPlaylist == nil)
      #expect(info.mainMediaFile == "main.fragmented.mp4")
      let audioTracks = info.audioTracks
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

    @Test("LUB-1060: Writes initialization before media and drains before finish returns")
    func writesInitializationBeforeMediaAndDrainsBeforeFinishReturns() async throws {
      let directory = URL(
        fileURLWithPath:
          "/private/tmp/LDTXAudioSideStreamPipelineIntegrationTestSuite-\(UUID().uuidString)",
        isDirectory: true
      )
      defer { try? FileManager.default.removeItem(at: directory) }

      let recorder = try HLSByteRangeTrackRecorder(
        directory: directory,
        mediaFileName: "InputDevices/Desk%20Microphone.mp4"
      )
      let pipeline = AudioSideStreamSegmentPipeline { Issue.record("Unexpected failure: \($0)") }
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

    @Test("LUB-1060: Snapshot uses the pre writer presentation start")
    func snapshotUsesThePreWriterPresentationStart() throws {
      let directory = URL(
        fileURLWithPath: "/private/tmp/LDTXTrackTimelineIntegrationTestSuite-\(UUID().uuidString)",
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

    @Test("LUB-1060: Perform is serialized with segment writes")
    func performIsSerializedWithSegmentWrites() async throws {
      let eventLog = AudioSideStreamPipelineEventLog()
      let pipeline = AudioSideStreamSegmentPipeline { Issue.record("Unexpected failure: \($0)") }
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
}

extension OutputTestSuite.AVAssetWriterLifecycleIntegrationTestSuite {
  @Suite struct AudioSideStreamFailureIntegrationTestSuite {
    enum FaultTiming: CaseIterable { case beforeFinish, duringFinish, finishResult }

    @Test("LUB-1060: Track refuses writes after terminal failure")
    func trackRefusesWritesAfterTerminalFailure() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let track = try HLSByteRangeTrackRecorder(directory: root, mediaFileName: "side.m4a")
      let primary = NSError(domain: NSCocoaErrorDomain, code: 640)
      track.markFailed(primary)
      do {
        try track.write(SegmentedMP4Segment(kind: .initialization, data: Data([1])))
        Issue.record("A failed track must not accept bytes")
      } catch {
        #expect((error as NSError) === primary)
      }
      #expect(try Data(contentsOf: root.appendingPathComponent("side.m4a")).isEmpty)
    }

    @Test(
      "LUB-1060: Fault drops queued writes and precedes concurrent finish", .timeLimit(.minutes(1)),
      arguments: [false, true])
    func faultDropsQueuedWritesAndPrecedesConcurrentFinish(externalFault: Bool) async throws {
      let primary = NSError(
        domain: NSCocoaErrorDomain, code: 640,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 28)])
      let events = Mutex<[String]>([])
      let entered = AsyncStream<Void>.makeStream()
      let release = DispatchSemaphore(value: 0)
      defer { release.signal() }
      let holder = Mutex<AudioSideStreamSegmentPipeline?>(nil)
      defer { holder.withLock { $0 = nil } }
      let pipeline = AudioSideStreamSegmentPipeline { error in
        #expect((error as NSError) === primary)
        // Reentering the fault gate proves notification is outside its lock.
        let pipeline = holder.withLock { $0 }
        #expect(pipeline?.hasFailed == true)
        pipeline?.fail(NSError(domain: "reentrant", code: 2))
        events.withLock { $0.append("failure") }
      }
      holder.withLock { $0 = pipeline }
      pipeline.start { segment in
        guard case .media(let number) = segment.kind else { return }
        events.withLock { $0.append("write-\(number)") }
        entered.continuation.yield(())
        #expect(release.wait(timeout: .now() + 10) == .success)
        if !externalFault { throw primary }
      }
      pipeline.yield(SegmentedMP4Segment(kind: .media(number: 1), data: Data([1])))
      var entering = entered.stream.makeAsyncIterator()
      _ = await entering.next()
      pipeline.yield(SegmentedMP4Segment(kind: .media(number: 2), data: Data([2])))
      let finished = AsyncStream<Void>.makeStream()
      for _ in 0..<2 {
        pipeline.finish {
          events.withLock { $0.append("finish") }
          finished.continuation.yield(())
        }
      }
      if externalFault {
        pipeline.fail(primary)
        pipeline.fail(NSError(domain: "later", code: 1))
      }
      release.signal()
      var completions = finished.stream.makeAsyncIterator()
      _ = await completions.next()
      _ = await completions.next()
      pipeline.yield(SegmentedMP4Segment(kind: .media(number: 3), data: Data([3])))
      await withCheckedContinuation { continuation in pipeline.drain { continuation.resume() } }
      #expect(events.withLock { $0 } == ["write-1", "failure", "finish", "finish"])
      #expect(pipeline.hasFailed)
    }

    @Test(
      "LUB-1060: Construction failure is terminal including silence fallback",
      .timeLimit(.minutes(1)), arguments: [false, true])
    func constructionFailureIsTerminalIncludingSilenceFallback(fallback: Bool) async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let track = try HLSByteRangeTrackRecorder(directory: root, mediaFileName: "side.m4a")
      let primary = NSError(domain: NSCocoaErrorDomain, code: 640)
      let failures = AsyncStream<NSError>.makeStream()
      let creations = Mutex(0)
      let recorder = try AudioSideStreamRecorder(
        trackRecorder: track, targetSegmentDurationSeconds: 2,
        failureHandler: { failures.continuation.yield($0 as NSError) },
        writerFactory: { _, _, _ in
          creations.withLock { $0 += 1 }
          throw primary
        })
      if fallback {
        await withCheckedContinuation { continuation in
          recorder.finish(at: CMTime(seconds: 1, preferredTimescale: 48_000)) {
            continuation.resume()
          }
        }
      } else {
        recorder.append(try makeSyntheticAudioSample(startFrame: 0, frameCount: 1_024))
      }
      var errors = failures.stream.makeAsyncIterator()
      #expect(await errors.next() === primary)
      recorder.append(try makeSyntheticAudioSample(startFrame: 1_024, frameCount: 1_024))
      await finishSyntheticSideRecorder(recorder)
      await finishSyntheticSideRecorder(recorder)
      #expect(creations.withLock { $0 } == 1)
      #expect(throws: (any Error).self) { try track.validateForFinalization() }
    }

    @Test(
      "LUB-1060: Asynchronous writer fault retains cause and coalesces finish waiters",
      .timeLimit(.minutes(1)), arguments: FaultTiming.allCases)
    func asynchronousWriterFaultRetainsCauseAndCoalescesFinishWaiters(timing: FaultTiming)
      async throws
    {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let track = try HLSByteRangeTrackRecorder(directory: root, mediaFileName: "side.m4a")
      let primary = NSError(
        domain: NSCocoaErrorDomain, code: 640,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 28)])
      let failures = Mutex<[NSError]>([])
      let callbacks = AsyncStream<Void>.makeStream()
      let writer = ControlledSideStreamWriter()
      let recorder = try AudioSideStreamRecorder(
        trackRecorder: track, targetSegmentDurationSeconds: 2,
        failureHandler: { error in
          failures.withLock { $0.append(error as NSError) }
          callbacks.continuation.yield(())
        },
        writerFactory: { _, _, callbacks in
          writer.install(callbacks)
          return writer
        })
      recorder.append(try makeSyntheticAudioSample(startFrame: 0, frameCount: 1_024))
      var appended = writer.appended.stream.makeAsyncIterator()
      _ = await appended.next()
      var delivered = callbacks.stream.makeAsyncIterator()
      if timing == .beforeFinish {
        writer.fault(primary)
        writer.fault(NSError(domain: "later", code: 90))
        _ = await delivered.next()
      }
      let stopping = Task {
        await withTaskGroup(of: Void.self) { group in
          for _ in 0..<8 {
            group.addTask { await finishSyntheticSideRecorder(recorder) }
          }
        }
      }
      var finishing = writer.finishing.stream.makeAsyncIterator()
      _ = await finishing.next()
      #expect(writer.finishCount.withLock { $0 } == 1)
      if timing == .duringFinish {
        writer.fault(primary)
        writer.fault(NSError(domain: "later", code: 90))
        _ = await delivered.next()
      }
      if timing == .finishResult {
        writer.complete(.failure(primary))
        _ = await delivered.next()
      }
      recorder.append(try makeSyntheticAudioSample(startFrame: 1_024, frameCount: 1_024))
      writer.segment(SegmentedMP4Segment(kind: .initialization, data: Data([9])))
      if timing != .finishResult {
        writer.complete(.failure(NSError(domain: "finish", code: 91)))
      }
      await stopping.value
      #expect(failures.withLock { $0.count } == 1)
      #expect(failures.withLock { $0.first } === primary)
      #expect(
        (failures.withLock { $0.first }?.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == 28)
      #expect(writer.appendCount.withLock { $0 } == 1)
      #expect(try Data(contentsOf: root.appendingPathComponent("side.m4a")).isEmpty)
      #expect(throws: (any Error).self) { try track.validateForFinalization() }
    }

    @Test(
      "LUB-1060: Real PCM writer asynchronous failure notifies before finish",
      .timeLimit(.minutes(1)))
    func realPCMWriterAsynchronousFailureNotifiesBeforeFinish() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let track = try HLSByteRangeTrackRecorder(directory: root, mediaFileName: "side.m4a")
      let primary = NSError(domain: NSCocoaErrorDomain, code: 640)
      let created = AsyncStream<PCMAudioSegmentedMP4Writer>.makeStream()
      let failures = AsyncStream<NSError>.makeStream()
      let recorder = try AudioSideStreamRecorder(
        trackRecorder: track, targetSegmentDurationSeconds: 2,
        failureHandler: { failures.continuation.yield($0 as NSError) },
        writerFactory: { format, duration, callbacks in
          let writer = try PCMAudioSegmentedMP4Writer(
            formatDescription: format, targetSegmentDurationSeconds: duration,
            onFailure: callbacks.onFailure, onSegment: callbacks.onSegment)
          created.continuation.yield(writer)
          return writer
        })
      recorder.append(try makeSyntheticAudioSample(startFrame: 0, frameCount: 1_024))
      var writers = created.stream.makeAsyncIterator()
      let writer = try #require(await writers.next())
      writer.cancel(with: primary)
      var errors = failures.stream.makeAsyncIterator()
      #expect(await errors.next() === primary)
      await finishSyntheticSideRecorder(recorder)
      #expect(throws: (any Error).self) { try track.validateForFinalization() }
    }

    @MainActor
    @Test(
      "LUB-1060: Audio only file failure reaches session before main failure",
      .timeLimit(.minutes(1)))
    func audioOnlyFileFailureReachesSessionBeforeMainFailure() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      var workspace = WorkspaceV4Bundle(definition: .init(), preferences: .init())
      let persistence = WorkspaceV4PersistenceCoordinator(
        workspaceSnapshot: { workspace }, replaceWorkspace: { workspace = $0 })
      let runtime = WorkspaceWindowRuntime(
        persistence: persistence,
        captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(
          captureServiceFactory: { preconditionFailure("No camera") },
          audioCaptureServiceFactory: { preconditionFailure("No microphone") }))
      defer { runtime.shutdown() }
      let session = WorkspaceV4RecordingSession(windowRuntime: runtime)
      let delivered = AsyncStream<NSError>.makeStream()
      let service = try SessionRecordService(
        baseDirectory: root, recordID: "audio-fault",
        writerConfiguration: SegmentedMP4WriterConfiguration(
          width: 320, height: 180, frameRate: 30, videoBitRate: 800_000),
        audioTracks: [
          SessionRecordAudioTrack(
            key: "side", deviceID: "fake", trackID: "side", displayName: "Side",
            fileNameStem: "InputDevices/Side")
        ],
        failureHandler: { error in
          delivered.continuation.yield(error as NSError)
          Task { await session.fail(error) }
        })
      try service.start()
      session.adoptStartedRecordingService(service)
      session.state = .recording
      let videos = try await makeSyntheticVideoSamples(frameCount: 1)
      try service.acceptFirstVideo(try #require(videos.first))
      let sample = try makeSyntheticAudioSample(startFrame: 0, frameCount: 1_024)
      service.appendMainAudioMix(sample)
      let package = service.packageDirectory
      try FileManager.default.removeItem(
        at: package.appendingPathComponent("InputDevices/Side.m4a"))
      for start in stride(from: 0, to: 144_000, by: 1_024) {
        service.appendInputAudio(
          try makeSyntheticAudioSample(startFrame: start, frameCount: 1_024), trackID: "side")
      }
      var errors = delivered.stream.makeAsyncIterator()
      let first = try #require(await errors.next())
      #expect(first.domain == NSCocoaErrorDomain)
      #expect(first.code == NSFileNoSuchFileError)
      // This callback arrives without requesting finish or failing the Main Mix.
      while session.state == .recording { await Task.yield() }
      _ = await session.stopWithResult()
      #expect(session.outputFailures.primary === first)
      let finalization = await withCheckedContinuation { continuation in
        service.stop { continuation.resume(returning: $0) }
      }
      guard case .failed(let finalError) = finalization else {
        Issue.record("The failed audio track must prevent successful finalization")
        return
      }
      #expect((finalError as NSError) === first)
      #expect(!hasFinalizedMarker(in: package))
    }
  }
}

private final class ControlledSideStreamWriter: AudioSideStreamWriting, @unchecked Sendable {
  private let callbacks = Mutex<AudioSideStreamWriterCallbacks?>(nil)
  private let completion = Mutex<(@Sendable (Result<Void, any Error>) -> Void)?>(nil)
  let appended = AsyncStream<Void>.makeStream()
  let finishing = AsyncStream<Void>.makeStream()
  let appendCount = Mutex(0)
  let finishCount = Mutex(0)
  func install(_ value: AudioSideStreamWriterCallbacks) { callbacks.withLock { $0 = value } }
  func append(_ sampleBuffer: CMSampleBuffer) {
    appendCount.withLock { $0 += 1 }
    appended.continuation.yield(())
  }
  func finish(
    at presentationTime: CMTime?,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    finishCount.withLock { $0 += 1 }
    completion.withLock { $0 = completionHandler }
    finishing.continuation.yield(())
  }
  func fault(_ error: any Error) { callbacks.withLock { $0 }?.onFailure(error) }
  func segment(_ segment: SegmentedMP4Segment) { callbacks.withLock { $0 }?.onSegment(segment) }
  func complete(_ result: Result<Void, any Error>) {
    let handler = completion.withLock {
      let handler = $0
      $0 = nil
      return handler
    }
    handler?(result)
    handler?(result)  // A duplicate completion must not resume finish waiters twice.
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

private func assertSyntheticRecordingTimingClocks(_ data: Data) throws {
  let boxes = try MP4TimingBox.parse(data)
  let movie = try #require(boxes.first { $0.type == MP4TimingBox.fourCC("moov") })
  let tracks = try MP4TimingBox.parse(movie.payload)
  let movieHeader = try #require(tracks.first { $0.type == MP4TimingBox.fourCC("mvhd") })
  #expect(try MP4TimingBox.read(movieHeader.payload, at: 12, bytes: 4) == 48_000)
  for track in tracks where track.type == MP4TimingBox.fourCC("trak") {
    let trackChildren = try MP4TimingBox.parse(track.payload)
    let media = try #require(
      trackChildren.first { $0.type == MP4TimingBox.fourCC("mdia") })
    let mediaChildren = try MP4TimingBox.parse(media.payload)
    let handler = try #require(
      mediaChildren.first { $0.type == MP4TimingBox.fourCC("hdlr") })
    let mediaHeader = try #require(
      mediaChildren.first { $0.type == MP4TimingBox.fourCC("mdhd") })
    let version = try MP4TimingBox.read(mediaHeader.payload, at: 0, bytes: 1)
    let timescaleOffset = version == 0 ? 12 : 20
    let timescale = try MP4TimingBox.read(mediaHeader.payload, at: timescaleOffset, bytes: 4)
    let handlerType = try MP4TimingBox.read(handler.payload, at: 8, bytes: 4)
    if handlerType == UInt64(MP4TimingBox.fourCC("soun")) {
      #expect(timescale == 48_000)
    } else if handlerType == UInt64(MP4TimingBox.fourCC("vide")) {
      #expect(timescale == 600)
    }
  }
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
