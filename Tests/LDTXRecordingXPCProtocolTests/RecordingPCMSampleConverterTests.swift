// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreMedia
import Foundation
import Testing

@testable import LDTXRecordingXPCProtocol

struct RecordingPCMSampleConverterTests {
  @Test
  func roundTripsInterleavedStereoPCM() throws {
    let original = try makeSampleBuffer(frameCount: 480, presentationValue: 960)
    let format = try RecordingPCMSampleConverter.formatRecord(from: original, sequence: 1)
    let buffer = try RecordingPCMSampleConverter.bufferRecord(from: original, sequence: 2)
    let rebuilt = try RecordingPCMSampleConverter.sampleBuffer(
      format: format.format,
      buffer: buffer.buffer
    )

    #expect(rebuilt.presentationTimeStamp == CMTime(value: 960, timescale: 48_000))
    #expect(CMSampleBufferGetNumSamples(rebuilt) == 480)
    #expect(CMBlockBufferGetDataLength(try #require(rebuilt.dataBuffer)) == 480 * 2 * 4)
    let rebuiltFormat = try #require(rebuilt.formatDescription)
    let description = try #require(
      CMAudioFormatDescriptionGetStreamBasicDescription(rebuiltFormat)
    ).pointee
    #expect(description.mSampleRate == 48_000)
    #expect(description.mChannelsPerFrame == 2)
    #expect(description.mFormatID == kAudioFormatLinearPCM)
  }

  private func makeSampleBuffer(
    frameCount: Int,
    presentationValue: CMTimeValue
  ) throws -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(
      mSampleRate: 48_000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 8,
      mFramesPerPacket: 1,
      mBytesPerFrame: 8,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 32,
      mReserved: 0
    )
    var format: CMAudioFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &asbd,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &format
    )
    #expect(formatStatus == noErr)
    let createdFormat = try #require(format)
    var block: CMBlockBuffer?
    let byteCount = frameCount * Int(asbd.mBytesPerFrame)
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: byteCount,
      blockAllocator: nil,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: byteCount,
      flags: 0,
      blockBufferOut: &block
    )
    #expect(blockStatus == kCMBlockBufferNoErr)
    let createdBlock = try #require(block)
    var samples = Data(count: byteCount)
    samples.withUnsafeMutableBytes { bytes in
      for index in bytes.indices {
        bytes[index] = UInt8(truncatingIfNeeded: index)
      }
    }
    let copyStatus = samples.withUnsafeBytes {
      CMBlockBufferReplaceDataBytes(
        with: $0.baseAddress!, blockBuffer: createdBlock,
        offsetIntoDestination: 0, dataLength: $0.count)
    }
    #expect(copyStatus == kCMBlockBufferNoErr)
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 48_000),
      presentationTimeStamp: CMTime(value: presentationValue, timescale: 48_000),
      decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: createdBlock,
      formatDescription: createdFormat,
      sampleCount: frameCount,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sample
    )
    #expect(sampleStatus == noErr)
    return try #require(sample)
  }
}
