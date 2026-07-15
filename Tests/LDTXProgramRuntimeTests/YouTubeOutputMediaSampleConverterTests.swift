// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import LDTXMP4
import LDTXYouTubeOutputProtocol
import XCTest

@testable import LDTXProgramRuntime

final class YouTubeOutputMediaSampleConverterTests: XCTestCase {
  func testConvertsEncodedH264SampleToFormatAndAccessUnit() async throws {
    let output = EncodedSampleOutput()
    let encoder = try H264VideoEncoder(
      configuration: H264VideoEncoderConfiguration(
        width: 320, height: 180, frameRate: 30, bitRate: 800_000)
    ) { output.append($0) }
    encoder.encode(
      pixelBuffer: try makePixelBuffer(width: 320, height: 180),
      presentationTime: CMTime(value: 90, timescale: 600),
      duration: CMTime(value: 20, timescale: 600))
    try await finish(encoder)
    let sample = try XCTUnwrap(try output.sampleBuffers().first)

    let format = try YouTubeOutputMediaSampleConverter.h264Format(from: sample)
    let accessUnit = try YouTubeOutputMediaSampleConverter.h264AccessUnit(from: sample)

    XCTAssertEqual(format.width, 320)
    XCTAssertEqual(format.height, 180)
    XCTAssertEqual(format.nalUnitHeaderLength, 4)
    XCTAssertGreaterThanOrEqual(format.parameterSets.count, 2)
    XCTAssertTrue(format.parameterSets.allSatisfy { !$0.isEmpty })
    XCTAssertEqual(accessUnit.presentationTime, YouTubeOutputMediaTime(value: 90, timescale: 600))
    XCTAssertEqual(accessUnit.duration, YouTubeOutputMediaTime(value: 20, timescale: 600))
    XCTAssertTrue(accessUnit.isKeyFrame)
    XCTAssertEqual(accessUnit.avccData, try data(from: sample))
    XCTAssertGreaterThan(accessUnit.avccData.count, 4)
  }

  func testConvertsInterleavedFloat32PCMWithTimestampAndFrameDuration() throws {
    let values: [Float32] = [0.25, -0.25, 0.5, -0.5]
    let bytes = values.withUnsafeBytes { Data($0) }
    let sample = try makePCMSample(data: bytes, frameCount: 2, startFrame: 480)

    let pcm = try YouTubeOutputMediaSampleConverter.pcmBuffer(from: sample)

    XCTAssertEqual(pcm.presentationTime, YouTubeOutputMediaTime(value: 480, timescale: 48_000))
    XCTAssertEqual(pcm.duration, YouTubeOutputMediaTime(value: 2, timescale: 48_000))
    XCTAssertEqual(pcm.sampleRate, 48_000)
    XCTAssertEqual(pcm.channelCount, 2)
    XCTAssertEqual(pcm.frameCount, 2)
    XCTAssertEqual(pcm.sampleFormat, .float32Interleaved)
    XCTAssertEqual(pcm.data, bytes)
  }

  func testRejectsNonInterleavedPCM() throws {
    var stream = AudioStreamBasicDescription(
      mSampleRate: 48_000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        | kAudioFormatFlagIsNonInterleaved,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 32,
      mReserved: 0)
    let sample = try makeAudioSample(
      data: Data(repeating: 0, count: 8), frameCount: 2, startFrame: 0, stream: &stream)

    XCTAssertThrowsError(try YouTubeOutputMediaSampleConverter.pcmBuffer(from: sample)) {
      guard case YouTubeOutputMediaSampleConverterError.unsupportedPCMFormat = $0 else {
        return XCTFail("unexpected error: \($0)")
      }
    }
  }

  private func finish(_ encoder: H264VideoEncoder) async throws {
    try await withCheckedThrowingContinuation { continuation in
      encoder.finish { continuation.resume(with: $0) }
    }
  }

  private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault, width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &pixelBuffer),
      kCVReturnSuccess)
    return try XCTUnwrap(pixelBuffer)
  }

  private func makePCMSample(data: Data, frameCount: Int, startFrame: Int) throws
    -> CMSampleBuffer
  {
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
    return try makeAudioSample(
      data: data, frameCount: frameCount, startFrame: startFrame, stream: &stream)
  }

  private func makeAudioSample(
    data: Data,
    frameCount: Int,
    startFrame: Int,
    stream: inout AudioStreamBasicDescription
  ) throws -> CMSampleBuffer {
    var createdBlockBuffer: CMBlockBuffer?
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
        blockBufferOut: &createdBlockBuffer),
      kCMBlockBufferNoErr)
    let blockBuffer = try XCTUnwrap(createdBlockBuffer)
    data.withUnsafeBytes { bytes in
      XCTAssertEqual(
        CMBlockBufferReplaceDataBytes(
          with: bytes.baseAddress!,
          blockBuffer: blockBuffer,
          offsetIntoDestination: 0,
          dataLength: data.count),
        kCMBlockBufferNoErr)
    }

    var formatDescription: CMAudioFormatDescription?
    XCTAssertEqual(
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &stream,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription),
      noErr)
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 48_000),
      presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: 48_000),
      decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    XCTAssertEqual(
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: try XCTUnwrap(formatDescription),
        sampleCount: frameCount,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer),
      noErr)
    return try XCTUnwrap(sampleBuffer)
  }

  private func data(from sample: CMSampleBuffer) throws -> Data {
    let block = try XCTUnwrap(sample.dataBuffer)
    let count = CMBlockBufferGetDataLength(block)
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { bytes in
      CMBlockBufferCopyDataBytes(
        block, atOffset: 0, dataLength: count, destination: bytes.baseAddress!)
    }
    XCTAssertEqual(status, kCMBlockBufferNoErr)
    return data
  }
}

private final class EncodedSampleOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Result<CMSampleBuffer, Error>] = []

  func append(_ result: Result<CMSampleBuffer, Error>) {
    lock.withLock { results.append(result) }
  }

  func sampleBuffers() throws -> [CMSampleBuffer] {
    try lock.withLock { try results.map { try $0.get() } }
  }
}
