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

struct AudioSideStreamSegmentPipelineTests {
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
        includesMainAudioTrack: false,
        audioTracks: [
          HLSByteRangeRecordingAudioTrack(
            id: SeparatedProgramRecordingPipeline.mainAudioTrackID,
            displayName: "Main Mix",
            fileNameStem: "output-audio"
          ),
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

    for startFrame in stride(from: 0, to: 144_000, by: 1_024) {
      let frameCount = min(1_024, 144_000 - startFrame)
      pipeline.appendAudio(
        try makeSyntheticAudioSample(startFrame: startFrame, frameCount: frameCount))
      sideRecorder.append(
        try makeSyntheticAudioSample(
          startFrame: startFrame + 9_600,
          frameCount: frameCount,
          frequency: 660
        ))
    }

    await finishSyntheticPipeline(pipeline)
    await finishSyntheticSideRecorder(sideRecorder)
    try #require(failures.values.isEmpty)
    try package.finish()

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
    #expect(duration.seconds > 2.8 && duration.seconds < 5)
    #expect(try await audioTracks[0].load(.isEnabled))
    #expect(!(try await audioTracks[1].load(.isEnabled)))
  }

  @Test func failedTrackPreventsFinalizedMarker() throws {
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
        includesMainAudioTrack: false,
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

  @Test func recordingPackageSupportsSeparateMainAudioRendition() throws {
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
        includesMainAudioTrack: false,
        audioTracks: [
          HLSByteRangeRecordingAudioTrack(
            id: "main",
            displayName: "Main Mix",
            fileNameStem: "output-audio"
          ),
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
    try package.audioTracks["main"]?.write(
      SegmentedMP4Segment(kind: .initialization, data: Data("main-init".utf8)))
    try package.audioTracks["main"]?.write(
      SegmentedMP4Segment(
        kind: .media(number: 1), data: Data("main-media".utf8),
        durationSeconds: 1.8, earliestPresentationTimeSeconds: 100.2))
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
    #expect(info["LDTXRecordingFormatVersion"] as? Int == 1)
    #expect(info["LDTXRecordingIdentifier"] as? String == "test")
    #expect(info["LDTXRecordingManifestFile"] as? String == "manifest.mpd")
    #expect(info["LDTXRecordingMasterPlaylist"] == nil)
    #expect(info["LDTXRecordingMainPlaylist"] == nil)
    #expect(info["LDTXRecordingMainMediaFile"] as? String == "output-video.mp4")
    let audioTracks = try #require(info["LDTXRecordingAudioTracks"] as? [[String: String]])
    #expect(
      audioTracks == [
        [
          "Identifier": "main",
          "Name": "Main Mix",
          "MediaFile": "output-audio.mp4",
        ],
        [
          "Identifier": "side",
          "Name": "Desk / Microphone",
          "MediaFile": "InputDevices/Desk%20%2F%20Microphone.mp4",
        ],
      ])

    let manifest = try String(
      contentsOf: directory.appendingPathComponent("manifest.mpd"),
      encoding: .utf8
    )
    #expect(manifest.contains("type=\"static\""))
    #expect(manifest.contains("presentationTimeOffset=\"100000000\""))
    #expect(manifest.contains("<S t=\"100000000\" d=\"2000000\"/>"))
    #expect(manifest.contains("<S t=\"100200000\" d=\"1800000\"/>"))
    #expect(manifest.contains("<Label>Desk / Microphone</Label>"))
    #expect(manifest.contains("media=\"InputDevices/Desk%2520%252F%2520Microphone.mp4\""))
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
    presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate)),
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
