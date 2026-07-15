// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import XCTest

@testable import LDTXMP4

final class H264VideoEncoderTests: XCTestCase {
  func testMultiplexerRejectsUnmatchedMediaSegmentNumbers() throws {
    XCTAssertNoThrow(
      try FragmentedMP4Multiplexer.validateMatchingMediaSegmentNumbers(
        video: [1, 2], audio: [1, 2]))
    XCTAssertThrowsError(
      try FragmentedMP4Multiplexer.validateMatchingMediaSegmentNumbers(
        video: [1, 2], audio: [1, 3])
    ) { error in
      guard
        case FragmentedMP4MultiplexerError.unmatchedMediaSegments(
          video: [2], audio: [3]) = error
      else { return XCTFail("unexpected error: \(error)") }
    }
  }

  func testPassthroughWriterPersistsInvalidSampleFailure() async throws {
    let failureReported = expectation(description: "failure reported")
    let writer = try H264PassthroughSegmentedMP4Writer(
      segmentDurationSeconds: 2,
      onFailure: { _ in failureReported.fulfill() },
      onSegment: { _ in })
    var invalidSample: CMSampleBuffer?
    XCTAssertEqual(
      CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: nil, sampleCount: 0,
        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0,
        sampleSizeArray: nil, sampleBufferOut: &invalidSample),
      noErr)

    writer.append(try XCTUnwrap(invalidSample))
    await fulfillment(of: [failureReported], timeout: 1)
    do {
      try await finish(writer)
      XCTFail("finish should preserve the append failure")
    } catch {
      XCTAssertTrue(error is H264PassthroughSegmentedMP4WriterError)
    }
  }

  func testPCMWriterPersistsInjectedAppendFailure() async throws {
    let first = try makeAudioSample(startFrame: 0, frameCount: 1_024)
    let failureReported = expectation(description: "failure reported")
    let writer = try PCMAudioSegmentedMP4Writer(
      formatDescription: try XCTUnwrap(first.formatDescription),
      segmentDurationSeconds: 2,
      onFailure: { _ in failureReported.fulfill() },
      onSegment: { _ in })

    writer.cancel(with: InjectedWriterError())
    await fulfillment(of: [failureReported], timeout: 1)
    do {
      try await finish(writer)
      XCTFail("finish should preserve the append failure")
    } catch {
      XCTAssertTrue(error is InjectedWriterError)
    }
  }

  func testMultiplexerProducesPlayableAudioVideoFragments() async throws {
    let encoded = H264EncoderOutput()
    let encoder = try H264VideoEncoder(
      configuration: H264VideoEncoderConfiguration(
        width: 320, height: 180, frameRate: 30, bitRate: 800_000)
    ) { encoded.append($0) }
    for index in 0..<120 {
      encoder.encode(
        pixelBuffer: try makePixelBuffer(width: 320, height: 180),
        presentationTime: CMTime(value: CMTimeValue(index), timescale: 30),
        duration: CMTime(value: 1, timescale: 30))
    }
    try await finish(encoder)

    let video = H264SegmentOutput()
    let videoWriter = try H264PassthroughSegmentedMP4Writer(segmentDurationSeconds: 2) {
      video.append($0)
    }
    for sample in try encoded.sampleBuffers() { videoWriter.append(sample) }

    let firstAudio = try makeAudioSample(startFrame: 0, frameCount: 1_024)
    let audio = H264SegmentOutput()
    let audioWriter = try PCMAudioSegmentedMP4Writer(
      formatDescription: try XCTUnwrap(firstAudio.formatDescription),
      segmentDurationSeconds: 2
    ) { audio.append($0) }
    audioWriter.append(firstAudio)
    for startFrame in stride(from: 1_024, to: 192_000, by: 1_024) {
      audioWriter.append(
        try makeAudioSample(
          startFrame: startFrame, frameCount: min(1_024, 192_000 - startFrame)))
    }
    try await finish(videoWriter)
    try await finish(audioWriter)

    let videoInitialization = try XCTUnwrap(
      video.values.first { $0.kind == .initialization }?.data)
    let audioInitialization = try XCTUnwrap(
      audio.values.first { $0.kind == .initialization }?.data)
    var output = try FragmentedMP4Multiplexer.initialization(
      video: videoInitialization, audio: audioInitialization)
    let videoMedia = Dictionary(
      uniqueKeysWithValues: video.values.compactMap { segment -> (Int, Data)? in
        if case .media(let number) = segment.kind { return (number, segment.data) }
        return nil
      })
    let audioMedia = Dictionary(
      uniqueKeysWithValues: audio.values.compactMap { segment -> (Int, Data)? in
        if case .media(let number) = segment.kind { return (number, segment.data) }
        return nil
      })
    let numbers = Set(videoMedia.keys).intersection(audioMedia.keys).sorted()
    XCTAssertFalse(numbers.isEmpty)
    for number in numbers {
      output.append(
        try FragmentedMP4Multiplexer.media(
          video: try XCTUnwrap(videoMedia[number]), audio: try XCTUnwrap(audioMedia[number])))
    }

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    try output.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let asset = AVURLAsset(url: url)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    XCTAssertEqual(videoTracks.count, 1)
    XCTAssertEqual(audioTracks.count, 1)
  }

  func testPassthroughSegmentWriterProducesVideoOnlyFragments() async throws {
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
    let writer = try H264PassthroughSegmentedMP4Writer(segmentDurationSeconds: 2) {
      segments.append($0)
    }
    for sampleBuffer in try output.sampleBuffers() {
      writer.append(sampleBuffer)
    }
    try await withCheckedThrowingContinuation { continuation in
      writer.finish { continuation.resume(with: $0) }
    }

    XCTAssertTrue(segments.values.contains { $0.kind == .initialization })
    XCTAssertTrue(
      segments.values.contains {
        if case .media = $0.kind { return true }
        return false
      })
  }

  func testEncoderProducesAVCCWithoutFrameReorderingAndCanForceKeyFrame() async throws {
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
    XCTAssertEqual(sampleBuffers.count, 3)
    XCTAssertTrue(isKeyFrame(sampleBuffers[0]))
    XCTAssertTrue(isKeyFrame(sampleBuffers[1]))

    for (index, sampleBuffer) in sampleBuffers.enumerated() {
      XCTAssertEqual(
        sampleBuffer.presentationTimeStamp, CMTime(value: CMTimeValue(index), timescale: 30))
      let decodeTime = sampleBuffer.decodeTimeStamp
      XCTAssertTrue(!decodeTime.isValid || decodeTime == sampleBuffer.presentationTimeStamp)
      try assertContainsValidAVCCAccessUnit(sampleBuffer)
    }
    try assertContainsH264ParameterSets(sampleBuffers[0])
  }

  func testEncoderKeepsKeyFrameIntervalWithinTwoSeconds() async throws {
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
    XCTAssertEqual(sampleBuffers.count, 70)
    XCTAssertGreaterThanOrEqual(keyFrameIndices.count, 2)
    XCTAssertEqual(keyFrameIndices.first, 0)
    for pair in zip(keyFrameIndices, keyFrameIndices.dropFirst()) {
      XCTAssertLessThanOrEqual(pair.1 - pair.0, 60)
    }
    XCTAssertLessThanOrEqual(69 - (try XCTUnwrap(keyFrameIndices.last)), 60)
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

  private func makeAudioSample(startFrame: Int, frameCount: Int) throws -> CMSampleBuffer {
    let sampleRate = 48_000
    let channelCount = 2
    var data = Data(count: frameCount * channelCount * MemoryLayout<Float32>.size)
    data.withUnsafeMutableBytes { bytes in
      let samples = bytes.bindMemory(to: Float32.self)
      for frame in 0..<frameCount {
        let value = Float32(sin(2 * Double.pi * 440 * Double(startFrame + frame) / 48_000) * 0.2)
        samples[frame * 2] = value
        samples[frame * 2 + 1] = value
      }
    }
    var block: CMBlockBuffer?
    XCTAssertEqual(
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
        blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
        dataLength: data.count, flags: 0, blockBufferOut: &block),
      kCMBlockBufferNoErr)
    let unwrappedBlock = try XCTUnwrap(block)
    data.withUnsafeBytes {
      XCTAssertEqual(
        CMBlockBufferReplaceDataBytes(
          with: $0.baseAddress!, blockBuffer: unwrappedBlock, offsetIntoDestination: 0,
          dataLength: data.count),
        kCMBlockBufferNoErr)
    }
    var stream = AudioStreamBasicDescription(
      mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
      mChannelsPerFrame: UInt32(channelCount), mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    XCTAssertEqual(
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &stream, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format),
      noErr)
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 48_000),
      presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: 48_000),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: unwrappedBlock,
        formatDescription: try XCTUnwrap(format), sampleCount: frameCount,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample),
      noErr)
    return try XCTUnwrap(sample)
  }

  private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
      &pixelBuffer
    )
    XCTAssertEqual(status, kCVReturnSuccess)
    return try XCTUnwrap(pixelBuffer)
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
    let dataBuffer = try XCTUnwrap(sampleBuffer.dataBuffer)
    let byteCount = CMBlockBufferGetDataLength(dataBuffer)
    XCTAssertGreaterThan(byteCount, 4)
    var bytes = [UInt8](repeating: 0, count: byteCount)
    XCTAssertEqual(
      CMBlockBufferCopyDataBytes(
        dataBuffer,
        atOffset: 0,
        dataLength: byteCount,
        destination: &bytes
      ),
      kCMBlockBufferNoErr
    )
    let firstNALUnitLength = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    XCTAssertGreaterThan(firstNALUnitLength, 0)
    XCTAssertLessThanOrEqual(firstNALUnitLength, byteCount - 4)
  }

  private func assertContainsH264ParameterSets(_ sampleBuffer: CMSampleBuffer) throws {
    let formatDescription = try XCTUnwrap(sampleBuffer.formatDescription)
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
    XCTAssertEqual(status, noErr)
    XCTAssertGreaterThanOrEqual(parameterSetCount, 2)
    XCTAssertEqual(nalUnitHeaderLength, 4)
  }
}

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
