// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import LDTXMP4
import LDTXYouTubeRTMPS
import XCTest

@testable import LDTXProgramRuntime

final class YouTubeRTMPSWorkspaceServiceTests: XCTestCase {
  func testStartsAfterBothCanvasFormatsAndDeliversBufferedMediaInOrder() async throws {
    let publisher = FakeDualRTMPSPublisher()
    let service = YouTubeRTMPSWorkspaceService(
      destinations: try destinations(),
      publisher: publisher,
      failureHandler: { XCTFail("unexpected failure: \($0)") })
    let video = try await makeVideoSample()
    let audio = try makePCMSample(frameCount: 2_048)

    async let publishing: Void = service.waitUntilPublishing()
    service.appendLandscapeVideo(video)
    service.appendLandscapeAudioMix(audio)
    service.appendPortraitVideo(video)
    service.appendPortraitAudioMix(audio)
    try await publishing
    let result = await service.finish()

    if case .failure(let error) = result { XCTFail("unexpected failure: \(error)") }
    let snapshot = await publisher.snapshot()
    XCTAssertEqual(snapshot.startCount, 1)
    XCTAssertEqual(snapshot.stopCount, 1)
    XCTAssertEqual(snapshot.videoCanvases, [.landscape, .portrait])
    XCTAssertTrue(snapshot.audioCanvases.contains(.landscape))
    XCTAssertTrue(snapshot.audioCanvases.contains(.portrait))
    XCTAssertFalse(snapshot.landscapeAudioSpecificConfig.isEmpty)
    XCTAssertFalse(snapshot.portraitAudioSpecificConfig.isEmpty)
  }

  func testPublishingWaitFailsWhenServiceFinishesBeforeFormatsArrive() async throws {
    let service = YouTubeRTMPSWorkspaceService(
      destinations: try destinations(),
      publisher: FakeDualRTMPSPublisher(),
      failureHandler: { XCTFail("unexpected failure: \($0)") })
    let waiter = Task { try await service.waitUntilPublishing() }

    _ = await service.finish()

    do {
      try await waiter.value
      XCTFail("expected stopped error")
    } catch {
      XCTAssertEqual(error as? YouTubeRTMPSWorkspaceServiceError, .stopped)
    }
  }

  func testFailsAndStopsWhenPendingMediaLimitIsExceeded() async throws {
    let publisher = FakeDualRTMPSPublisher()
    let failure = expectation(description: "failure")
    let service = YouTubeRTMPSWorkspaceService(
      destinations: try destinations(),
      publisher: publisher,
      pendingMediaLimit: 1,
      failureHandler: { error in
        XCTAssertEqual(
          error as? YouTubeRTMPSWorkspaceServiceError, .pendingMediaLimitExceeded)
        failure.fulfill()
      })
    let video = try await makeVideoSample()

    service.appendLandscapeVideo(video)
    service.appendPortraitVideo(video)
    await fulfillment(of: [failure], timeout: 2)
    let result = await service.finish()

    guard case .failure(let error) = result else {
      return XCTFail("expected failure")
    }
    XCTAssertEqual(error as? YouTubeRTMPSWorkspaceServiceError, .pendingMediaLimitExceeded)
    let snapshot = await publisher.snapshot()
    XCTAssertEqual(snapshot.startCount, 0)
    XCTAssertGreaterThanOrEqual(snapshot.stopCount, 1)
  }

  private func destinations() throws -> YouTubeDualRTMPSDestinations {
    try YouTubeDualRTMPSDestinations(
      landscape: YouTubeRTMPSDestination(
        ingestionURL: XCTUnwrap(URL(string: "rtmps://a.rtmp.youtube.com/live2")),
        streamName: "landscape"),
      portrait: YouTubeRTMPSDestination(
        ingestionURL: XCTUnwrap(URL(string: "rtmps://b.rtmp.youtube.com/live2")),
        streamName: "portrait"))
  }

  private func makeVideoSample() async throws -> CMSampleBuffer {
    let output = EncodedRTMPSSampleOutput()
    let encoder = try H264VideoEncoder(
      configuration: H264VideoEncoderConfiguration(
        width: 320, height: 180, frameRate: 30, bitRate: 800_000)
    ) { output.append($0) }
    encoder.encode(
      pixelBuffer: try makePixelBuffer(width: 320, height: 180),
      presentationTime: CMTime(value: 60, timescale: 600),
      duration: CMTime(value: 20, timescale: 600))
    try await withCheckedThrowingContinuation { continuation in
      encoder.finish { continuation.resume(with: $0) }
    }
    return try XCTUnwrap(try output.sampleBuffers().first)
  }

  private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault, width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &pixelBuffer),
      kCVReturnSuccess)
    return try XCTUnwrap(pixelBuffer)
  }

  private func makePCMSample(frameCount: Int) throws -> CMSampleBuffer {
    let data = Data(repeating: 0, count: frameCount * 2 * MemoryLayout<Float32>.size)
    var blockBuffer: CMBlockBuffer?
    XCTAssertEqual(
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: data.count,
        blockAllocator: nil,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: data.count,
        flags: 0,
        blockBufferOut: &blockBuffer),
      kCMBlockBufferNoErr)
    let buffer = try XCTUnwrap(blockBuffer)
    data.withUnsafeBytes { bytes in
      XCTAssertEqual(
        CMBlockBufferReplaceDataBytes(
          with: bytes.baseAddress!,
          blockBuffer: buffer,
          offsetIntoDestination: 0,
          dataLength: data.count),
        kCMBlockBufferNoErr)
    }
    var stream = AudioStreamBasicDescription(
      mSampleRate: 48_000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 8,
      mFramesPerPacket: 1,
      mBytesPerFrame: 8,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 32,
      mReserved: 0)
    var format: CMAudioFormatDescription?
    XCTAssertEqual(
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &stream,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &format),
      noErr)
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 48_000),
      presentationTimeStamp: CMTime(value: 48_000, timescale: 48_000),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: buffer,
        formatDescription: try XCTUnwrap(format),
        sampleCount: frameCount,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sample),
      noErr)
    return try XCTUnwrap(sample)
  }
}

private actor FakeDualRTMPSPublisher: YouTubeDualRTMPSPublishing {
  struct Snapshot: Sendable {
    var startCount: Int
    var stopCount: Int
    var videoCanvases: [YouTubeRTMPSCanvas]
    var audioCanvases: [YouTubeRTMPSCanvas]
    var landscapeAudioSpecificConfig: Data
    var portraitAudioSpecificConfig: Data
  }

  private var startCount = 0
  private var stopCount = 0
  private var videoCanvases: [YouTubeRTMPSCanvas] = []
  private var audioCanvases: [YouTubeRTMPSCanvas] = []
  private var landscapeAudioSpecificConfig = Data()
  private var portraitAudioSpecificConfig = Data()

  func start(
    destinations _: YouTubeDualRTMPSDestinations,
    landscapeVideoFormat _: YouTubeRTMPSVideoFormat,
    portraitVideoFormat _: YouTubeRTMPSVideoFormat,
    landscapeAudioFormat: YouTubeRTMPSAudioFormat,
    portraitAudioFormat: YouTubeRTMPSAudioFormat
  ) async throws {
    startCount += 1
    landscapeAudioSpecificConfig = landscapeAudioFormat.audioSpecificConfig
    portraitAudioSpecificConfig = portraitAudioFormat.audioSpecificConfig
  }

  func appendVideo(
    _: YouTubeRTMPSVideoSample,
    canvas: YouTubeRTMPSCanvas
  ) async throws {
    videoCanvases.append(canvas)
  }

  func appendAudio(
    _: YouTubeRTMPSAudioSample,
    canvas: YouTubeRTMPSCanvas
  ) async throws {
    audioCanvases.append(canvas)
  }

  func stop() async { stopCount += 1 }

  func snapshot() -> Snapshot {
    Snapshot(
      startCount: startCount,
      stopCount: stopCount,
      videoCanvases: videoCanvases,
      audioCanvases: audioCanvases,
      landscapeAudioSpecificConfig: landscapeAudioSpecificConfig,
      portraitAudioSpecificConfig: portraitAudioSpecificConfig)
  }
}

private final class EncodedRTMPSSampleOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Result<CMSampleBuffer, Error>] = []

  func append(_ result: Result<CMSampleBuffer, Error>) {
    lock.withLock { results.append(result) }
  }

  func sampleBuffers() throws -> [CMSampleBuffer] {
    try lock.withLock { try results.map { try $0.get() } }
  }
}
