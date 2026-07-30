// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import LDTXMP4
import LDTXOutputMedia
import LDTXRecording
import LDTXRecordingXPCProtocol
import Testing

@testable import LDTXProgramRuntime

struct AudioSideStreamSegmentPipelineTests {
  @Test func externalFragmentKindDoesNotDependOnDurationMetadata() throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXExternalFragmentTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try HLSByteRangeTrackRecorder(
      directory: directory,
      mediaFileName: "main.mp4"
    )
    var initialization = Ldtx_Recording_Xpc_V1_Event()
    initialization.kind = .fragmentCommitted
    initialization.fragmentKind = .initialization
    initialization.byteLength = 100
    recorder.recordExternalFragment(initialization)

    var media = Ldtx_Recording_Xpc_V1_Event()
    media.kind = .fragmentCommitted
    media.fragmentKind = .media
    media.byteOffset = 100
    media.byteLength = 200
    recorder.recordExternalFragment(media)

    let snapshot = try #require(recorder.durableSnapshot())
    #expect(snapshot.initialization == MP4ByteRange(offset: 0, length: 100))
    #expect(snapshot.segments.count == 1)
    #expect(snapshot.segments[0].range == MP4ByteRange(offset: 100, length: 200))
    #expect(snapshot.segments[0].durationSeconds == 0.001)
  }

  @Test func externalAudioFragmentPreservesPresentationStartOffset() throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXXPCAudioStartTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try HLSByteRangeTrackRecorder(
      directory: directory,
      mediaFileName: "main.mp4"
    )
    var initialization = Ldtx_Recording_Xpc_V1_Event()
    initialization.fragmentKind = .initialization
    initialization.byteLength = 100
    recorder.recordExternalFragment(initialization)
    var media = Ldtx_Recording_Xpc_V1_Event()
    media.fragmentKind = .media
    media.byteOffset = 100
    media.byteLength = 200
    media.presentationValue = 100_000
    media.presentationTimescale = 1_000_000
    media.durationValue = 10_000
    media.durationTimescale = 1_000_000
    recorder.recordExternalFragment(media)

    let snapshot = try #require(recorder.durableSnapshot())
    #expect(snapshot.segments[0].earliestPresentationTimeSeconds == 0.1)
  }

  @Test func syntheticRecordingFinalizesAndRemuxesToOneMultitrackMP4() async throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXSyntheticRecordingTests-\(UUID().uuidString).ldtxrecord",
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
        audioTracks: [
          HLSByteRangeRecordingAudioTrack(
            id: "desk-microphone",
            displayName: "Desk Microphone",
            fileNameStem: "InputDevices/Desk%20Microphone"
          ),
        ]
      )
    )
    let normalizer = RecordingTimelineNormalizer(origin: .zero)
    let failures = SyntheticRecordingFailures()
    let pipeline = try SeparatedProgramRecordingPipeline(
      package: package,
      segmentDurationSeconds: 2,
      startNumber: 1,
      timelineNormalizer: normalizer,
      failureHandler: { failures.append($0) }
    )
    let sideTrack = try #require(package.audioTracks["desk-microphone"])
    let sideRecorder = try AudioSideStreamRecorder(
      trackRecorder: sideTrack,
      segmentDurationSeconds: 2,
      timelineNormalizer: normalizer,
      timelineTrackID: "desk-microphone"
    )

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

    var programAACEncoder: AACAudioEncoder?
    for startFrame in stride(from: 0, to: 144_000, by: 1_024) {
      let frameCount = min(1_024, 144_000 - startFrame)
      let programAudio = try makeSyntheticAudioSample(
        startFrame: startFrame, frameCount: frameCount)
      if programAACEncoder == nil {
        programAACEncoder = try AACAudioEncoder(
          inputFormatDescription: try #require(programAudio.formatDescription))
      }
      for encodedAudio in try #require(programAACEncoder).encode(programAudio) {
        pipeline.appendProgramAudio(try makeProgramAudioPacket(encodedAudio))
      }
      sideRecorder.append(
        try makeSyntheticAudioSample(
          startFrame: startFrame + 9_600,
          frameCount: frameCount,
          frequency: 660
        ))
    }
    for encodedAudio in try #require(programAACEncoder).finish() {
      pipeline.appendProgramAudio(try makeProgramAudioPacket(encodedAudio))
    }

    await finishSyntheticPipeline(pipeline)
    await finishSyntheticSideRecorder(sideRecorder)
    try #require(failures.values.isEmpty)
    // Exercise Format v2 remuxing with a second durable Main generation. The
    // copied fMP4 deliberately keeps native timestamps; the new DASH Period
    // supplies the presentation-time shift that the remuxer must preserve.
    let firstGeneration = try #require(package.mainTrack.durableSnapshot())
    let recoveredURL = directory.appendingPathComponent("main~2.mp4")
    try FileManager.default.copyItem(at: directory.appendingPathComponent("main.mp4"), to: recoveredURL)
    var recoveredGeneration = firstGeneration
    recoveredGeneration.mediaFileName = "main~2.mp4"
    recoveredGeneration.segments = recoveredGeneration.segments.map { segment in
      var segment = segment
      segment.earliestPresentationTimeSeconds += 4
      return segment
    }
    try package.completeSession(
      additionalPeriods: [
        HLSByteRangeRecordingPeriod(id: "generation-2", main: recoveredGeneration, audio: [])
      ]
    )

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
    // AVAssetWriter may extend a fragmented track to the next fragment boundary under load.
    // Keep this bound tight enough to catch the historical multi-hour timestamp regression.
    #expect(duration.seconds > 6.8 && duration.seconds < 9)
    #expect(try await audioTracks[0].load(.isEnabled))
    #expect(!(try await audioTracks[1].load(.isEnabled)))
  }

  @Test func failedTrackKeepsDurableFragmentsWhenSessionCompletes() throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXFailedRecordingTests-\(UUID().uuidString)",
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
        audioTracks: [
          HLSByteRangeRecordingAudioTrack(
            id: "main",
            displayName: "Main Mix",
            fileNameStem: "output-audio"
          )
        ]
      )
    )
    try package.mainTrack.write(
      SegmentedMP4Segment(kind: .initialization, data: Data("video-init".utf8)))
    try package.mainTrack.write(
      SegmentedMP4Segment(
        kind: .media(number: 1), data: Data("video-media".utf8),
        durationSeconds: 1, earliestPresentationTimeSeconds: 0))
    let audioTrack = try #require(package.audioTracks["main"])
    try audioTrack.write(
      SegmentedMP4Segment(kind: .initialization, data: Data("audio-init".utf8)))
    try audioTrack.write(
      SegmentedMP4Segment(
        kind: .media(number: 1), data: Data("audio-media".utf8),
        durationSeconds: 1, earliestPresentationTimeSeconds: 0))
    audioTrack.markFailed(TestRecordingFailure())

    try package.completeSession()
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(
          RecordingPackage.finalizedMarkerFileName
        ).path
      )
    )
    let manifest = try String(
      contentsOf: directory.appendingPathComponent(RecordingPackage.manifestFileName),
      encoding: .utf8
    )
    #expect(manifest.contains("main.mp4"))
  }

  @Test func recoveryGenerationWritesASeparateDASHPeriod() throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXRecoveryGenerationTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try HLSByteRangeRecordingPackage(
      configuration: HLSByteRangeRecordingPackageConfiguration(
        directory: directory,
        recordID: "recovery-test",
        targetDurationSeconds: 2,
        videoCodecs: "avc1.64002a",
        audioCodecs: "mp4a.40.2",
        bandwidth: 1_000_000,
        audioTracks: []
      )
    )
    try package.mainTrack.write(SegmentedMP4Segment(kind: .initialization, data: Data("init-1".utf8)))
    try package.mainTrack.write(SegmentedMP4Segment(kind: .media(number: 1), data: Data("media-1".utf8), durationSeconds: 2, earliestPresentationTimeSeconds: 0))

    let recoveredTrack = try HLSByteRangeTrackRecorder(directory: directory, mediaFileName: "main~2.mp4")
    try recoveredTrack.write(SegmentedMP4Segment(kind: .initialization, data: Data("init-2".utf8)))
    try recoveredTrack.write(SegmentedMP4Segment(kind: .media(number: 1), data: Data("media-2".utf8), durationSeconds: 2, earliestPresentationTimeSeconds: 4))
    recoveredTrack.finish()
    let recoveredSnapshot = try #require(recoveredTrack.durableSnapshot())

    try package.completeSession(
      additionalPeriods: [HLSByteRangeRecordingPeriod(id: "generation-2", main: recoveredSnapshot, audio: [])]
    )
    let manifest = try String(contentsOf: directory.appendingPathComponent(RecordingPackage.manifestFileName), encoding: .utf8)
    #expect(manifest.contains("<Period id=\"generation-1\" start=\"PT0.000000S\">"))
    #expect(manifest.contains("<Period id=\"generation-2\" start=\"PT4.000000S\">"))
    #expect(manifest.contains("main.mp4"))
    #expect(manifest.contains("main~2.mp4"))
  }

  @Test func inputAudioRecoveryGenerationWritesAnIndependentDASHPeriod() throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXInputRecoveryGenerationTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = HLSByteRangeRecordingAudioTrack(
      id: "microphone",
      displayName: "Microphone",
      fileNameStem: "InputDevices/Microphone"
    )
    let package = try HLSByteRangeRecordingPackage(
      configuration: HLSByteRangeRecordingPackageConfiguration(
        directory: directory,
        recordID: "input-recovery-test",
        targetDurationSeconds: 2,
        videoCodecs: "avc1.64002a",
        audioCodecs: "mp4a.40.2",
        bandwidth: 1_000_000,
        audioTracks: [input]
      )
    )
    let recovered = try package.makeInputAudioGenerationTrack(input, generation: 2)
    try recovered.write(SegmentedMP4Segment(kind: .initialization, data: Data("init-2".utf8)))
    try recovered.write(
      SegmentedMP4Segment(
        kind: .media(number: 1),
        data: Data("media-2".utf8),
        durationSeconds: 2,
        earliestPresentationTimeSeconds: 4
      )
    )
    recovered.finish()
    let snapshot = try #require(recovered.durableSnapshot())

    try package.completeSession(
      additionalPeriods: [
        HLSByteRangeRecordingPeriod(
          id: "input-microphone-generation-2",
          main: nil,
          audio: [(input, snapshot)]
        )
      ]
    )
    let manifest = try String(
      contentsOf: directory.appendingPathComponent(RecordingPackage.manifestFileName),
      encoding: .utf8
    )
    #expect(manifest.contains("InputDevices/Microphone~2.m4a"))
    #expect(manifest.contains("input-microphone-generation-2"))
  }

  @Test func sessionCompletionMarkerDoesNotAssertMediaCompleteness() async throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXEmptyRecordingTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try HLSByteRangeRecordingPackage(
      configuration: HLSByteRangeRecordingPackageConfiguration(
        directory: directory,
        recordID: "empty-test",
        targetDurationSeconds: 2,
        videoCodecs: "avc1.64002a",
        audioCodecs: "mp4a.40.2",
        bandwidth: 1_000_000,
        audioTracks: []
      )
    )

    try package.completeSession()

    let recording = try RecordingPackage(contentsOf: directory)
    #expect(recording.isFinalized)
    let manifest = try String(
      contentsOf: directory.appendingPathComponent(RecordingPackage.manifestFileName),
      encoding: .utf8
    )
    #expect(!manifest.contains("<Representation"))
    await #expect(throws: RecordingPackageVerificationError.self) {
      try await RecordingPackageVerifier().verify(recording)
    }
  }

  @Test func recordingPackageUsesMuxedMainProgramAndInputAudioRenditions() throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXSeparatedRecordingTests-\(UUID().uuidString)",
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
        audioTracks: [
          HLSByteRangeRecordingAudioTrack(
            id: "side",
            displayName: "Desk / Microphone",
            fileNameStem: "InputDevices/Desk%20%2F%20Microphone"
          ),
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
    try package.completeSession()

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
    #expect(info["LDTXRecordingMainMediaFile"] as? String == "main.mp4")
    let audioTracks = try #require(info["LDTXRecordingAudioTracks"] as? [[String: String]])
    #expect(
      audioTracks == [
        [
          "Identifier": "side",
          "Name": "Desk / Microphone",
          "MediaFile": "InputDevices/Desk%20%2F%20Microphone.m4a",
        ],
      ])

    let manifest = try String(
      contentsOf: directory.appendingPathComponent("manifest.mpd"),
      encoding: .utf8
    )
    #expect(manifest.contains("type=\"static\""))
    #expect(manifest.contains("presentationTimeOffset=\"100000000\""))
    #expect(manifest.contains("<S t=\"100000000\" d=\"2000000\"/>"))
    #expect(manifest.contains("<Label>Desk / Microphone</Label>"))
    #expect(manifest.contains("media=\"InputDevices/Desk%2520%252F%2520Microphone.m4a\""))
  }

  @Test func writesInitializationBeforeMediaAndDrainsBeforeFinishReturns() async throws {
    let directory = URL(
      fileURLWithPath: "/private/tmp/LDTXAudioSideStreamPipelineTests-\(UUID().uuidString)",
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
      fileURLWithPath: "/private/tmp/LDTXTrackTimelineTests-\(UUID().uuidString)",
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

  @Test func boundsPendingSegmentsWithoutBlockingTheProducer() throws {
    let enteredWrite = DispatchSemaphore(value: 0)
    let releaseWrite = DispatchSemaphore(value: 0)
    let pipeline = AudioSideStreamSegmentPipeline(maximumPendingSegments: 1)
    pipeline.start { _ in
      enteredWrite.signal()
      releaseWrite.wait()
    }

    #expect(pipeline.yield(SegmentedMP4Segment(kind: .initialization, data: Data())))
    #expect(enteredWrite.wait(timeout: .now() + 1) == .success)
    #expect(!pipeline.yield(SegmentedMP4Segment(kind: .media(number: 1), data: Data())))

    releaseWrite.signal()
    let finished = DispatchSemaphore(value: 0)
    pipeline.finish { finished.signal() }
    #expect(finished.wait(timeout: .now() + 1) == .success)
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

private func finishSyntheticEncoder(_ encoder: H264VideoEncoder) async throws {
  try await withCheckedThrowingContinuation { continuation in
    encoder.finish { continuation.resume(with: $0) }
  }
}

private func finishSyntheticPipeline(_ pipeline: SeparatedProgramRecordingPipeline) async {
  await withCheckedContinuation { continuation in
    pipeline.finish { continuation.resume() }
  }
}

private func finishSyntheticSideRecorder(_ recorder: AudioSideStreamRecorder) async {
  await withCheckedContinuation { continuation in
    recorder.finish { continuation.resume() }
  }
}

private func makeProgramAudioPacket(_ sampleBuffer: CMSampleBuffer) throws -> ProgramOutputAACPacket {
  try ProgramOutputAACPacket(
    format: ProgramOutputMediaSampleConverter.aacFormat(from: sampleBuffer),
    accessUnit: ProgramOutputMediaSampleConverter.aacAccessUnit(from: sampleBuffer))
}

private func makeSyntheticPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
  var pixelBuffer: CVPixelBuffer?
  let status = CVPixelBufferCreate(
    kCFAllocatorDefault,
    width,
    height,
    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
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
