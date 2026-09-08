// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import LDTXMP4
import LDTXYouTubeOutputProtocol
import LDTXYouTubeRTMPS
import Testing

@testable import LDTXProgramRuntime

@Suite("LDTXProgramRuntimeHardTests", .tags(.hard))
struct YouTubeOutputMediaSampleConverterTests {
  @Test func keepsRawAACAudioSpecificConfigMagicCookie() {
    let cookie = Data([0x11, 0x90])

    #expect(
      YouTubeOutputMediaSampleConverter.audioSpecificConfig(fromMagicCookie: cookie) == cookie)
  }

  @Test func extractsAACAudioSpecificConfigFromESDSMagicCookie() {
    let cookie = Data([
      0x03, 0x80, 0x80, 0x80, 0x22, 0x00, 0x00, 0x00, 0x04, 0x80, 0x80, 0x80, 0x14,
      0x40, 0x14, 0x00, 0x18, 0x00, 0x00, 0x01, 0xf4, 0x00, 0x00, 0x01, 0xf4, 0x00,
      0x05, 0x80, 0x80, 0x80, 0x02, 0x11, 0x90, 0x06, 0x80, 0x80, 0x80, 0x01, 0x02,
    ])

    #expect(
      YouTubeOutputMediaSampleConverter.audioSpecificConfig(fromMagicCookie: cookie)
        == Data([0x11, 0x90]))
  }

  @Test func rejectsMalformedESDSMagicCookie() {
    let cookie = Data([0x03, 0x80, 0x80, 0x80, 0x01, 0x05, 0x82, 0x01])

    #expect(
      YouTubeOutputMediaSampleConverter.audioSpecificConfig(fromMagicCookie: cookie) == nil)
  }

  @Test func convertsHighResolutionTimeWithoutIntermediateOverflow() throws {
    let time = YouTubeOutputMediaTime(
      value: 9_223_372_036_000_000, timescale: 1_000_000_000)

    let converted = try YouTubeOutputMediaSampleConverter.rtmpsTime(time)

    #expect(converted.milliseconds == 9_223_372_036)
  }

  @Test func convertsEncodedH264SampleToFormatAndAccessUnit() async throws {
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
    let sample = try #require(try output.sampleBuffers().first)

    let format = try YouTubeOutputMediaSampleConverter.h264Format(from: sample)
    let accessUnit = try YouTubeOutputMediaSampleConverter.h264AccessUnit(from: sample)

    #expect(format.width == 320)
    #expect(format.height == 180)
    #expect(format.nalUnitHeaderLength == 4)
    #expect(format.parameterSets.count >= 2)
    #expect(format.parameterSets.allSatisfy { !$0.isEmpty })
    #expect(accessUnit.presentationTime == YouTubeOutputMediaTime(value: 90, timescale: 600))
    #expect(accessUnit.duration == YouTubeOutputMediaTime(value: 20, timescale: 600))
    #expect(accessUnit.isKeyFrame)
    #expect(try accessUnit.avccData == data(from: sample))
    #expect(accessUnit.avccData.count > 4)

    let rtmpsFormat = try YouTubeOutputMediaSampleConverter.rtmpsVideoFormat(from: sample)
    let rtmpsSample = try YouTubeOutputMediaSampleConverter.rtmpsVideoSample(from: sample)
    #expect(rtmpsFormat.sequenceParameterSet == format.parameterSets[0])
    #expect(rtmpsFormat.pictureParameterSet == format.parameterSets[1])
    #expect(rtmpsFormat.nalUnitHeaderLength == 4)
    #expect(rtmpsSample.avccData == accessUnit.avccData)
    #expect(rtmpsSample.presentationTime.milliseconds == 150)
    #expect(rtmpsSample.decodeTime.milliseconds == 150)
    #expect(rtmpsSample.isKeyFrame)
  }

  @Test func convertsEncodedAACFormatAndPackets() throws {
    let pcm = try makePCMSample(
      data: Data(repeating: 0, count: 8 * 2_048), frameCount: 2_048, startFrame: 0)
    let encoder = try AACAudioEncoder(
      inputFormatDescription: try #require(pcm.formatDescription))
    var encoded = try encoder.encode(pcm)
    encoded.append(contentsOf: try encoder.finish())
    let sample = try #require(encoded.first)

    let format = try YouTubeOutputMediaSampleConverter.rtmpsAudioFormat(
      from: try #require(sample.formatDescription))
    let packets = try YouTubeOutputMediaSampleConverter.rtmpsAudioSamples(from: sample)

    #expect(!format.audioSpecificConfig.isEmpty)
    #expect(packets.count == CMSampleBufferGetNumSamples(sample))
    #expect(packets.allSatisfy { !$0.rawAACData.isEmpty })
    #expect(
      packets.first?.presentationTime.milliseconds
        == sample.presentationTimeStamp.value * 1_000
        / Int64(sample.presentationTimeStamp.timescale))
    for index in packets.indices {
      var timing = CMSampleTimingInfo()
      #expect(
        CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing) == noErr)
      #expect(
        packets[index].presentationTime.milliseconds
          == timing.presentationTimeStamp.value * 1_000
          / Int64(timing.presentationTimeStamp.timescale))
    }
  }

  @Test func convertsInterleavedFloat32PCMWithTimestampAndFrameDuration() throws {
    let values: [Float32] = [0.25, -0.25, 0.5, -0.5]
    let bytes = values.withUnsafeBytes { Data($0) }
    let sample = try makePCMSample(data: bytes, frameCount: 2, startFrame: 480)

    let pcm = try YouTubeOutputMediaSampleConverter.pcmBuffer(from: sample)

    #expect(pcm.presentationTime == YouTubeOutputMediaTime(value: 480, timescale: 48_000))
    #expect(pcm.duration == YouTubeOutputMediaTime(value: 2, timescale: 48_000))
    #expect(pcm.sampleRate == 48_000)
    #expect(pcm.channelCount == 2)
    #expect(pcm.frameCount == 2)
    #expect(pcm.sampleFormat == .float32Interleaved)
    #expect(pcm.data == bytes)
  }

  @Test func rejectsNonInterleavedPCM() throws {
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

    #expect(throws: YouTubeOutputMediaSampleConverterError.unsupportedPCMFormat) {
      try YouTubeOutputMediaSampleConverter.pcmBuffer(from: sample)
    }
  }

  private func finish(_ encoder: H264VideoEncoder) async throws {
    try await withCheckedThrowingContinuation { continuation in
      encoder.finish { continuation.resume(with: $0) }
    }
  }

  private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
      &pixelBuffer)
    #expect(status == kCVReturnSuccess)
    return try #require(pixelBuffer)
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
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: data.count,
      blockAllocator: nil,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: data.count,
      flags: 0,
      blockBufferOut: &createdBlockBuffer)
    #expect(blockStatus == kCMBlockBufferNoErr)
    let blockBuffer = try #require(createdBlockBuffer)
    data.withUnsafeBytes { bytes in
      let replaceStatus = CMBlockBufferReplaceDataBytes(
        with: bytes.baseAddress!,
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: data.count)
      #expect(replaceStatus == kCMBlockBufferNoErr)
    }

    var formatDescription: CMAudioFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &stream,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &formatDescription)
    #expect(formatStatus == noErr)
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 48_000),
      presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: 48_000),
      decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: formatDescription,
      sampleCount: frameCount,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sampleBuffer)
    #expect(sampleStatus == noErr)
    return try #require(sampleBuffer)
  }

  private func data(from sample: CMSampleBuffer) throws -> Data {
    let block = try #require(sample.dataBuffer)
    let count = CMBlockBufferGetDataLength(block)
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { bytes in
      CMBlockBufferCopyDataBytes(
        block, atOffset: 0, dataLength: count, destination: bytes.baseAddress!)
    }
    #expect(status == kCMBlockBufferNoErr)
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
