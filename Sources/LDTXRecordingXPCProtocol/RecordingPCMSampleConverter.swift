// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreMedia
import Foundation

public enum RecordingPCMSampleConverterError: Error {
  case missingFormat
  case unsupportedFormat
  case missingData
  case invalidTiming
  case cannotCreateBlockBuffer(OSStatus)
  case cannotCreateFormat(OSStatus)
  case cannotCreateSample(OSStatus)
}

public enum RecordingPCMSampleConverter {
  public static func formatRecord(
    from sampleBuffer: CMSampleBuffer,
    sequence: UInt64
  ) throws -> Ldtx_Recording_Xpc_V1_AudioRingRecord {
    guard let description = sampleBuffer.formatDescription,
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
    else { throw RecordingPCMSampleConverterError.missingFormat }
    guard asbd.mFormatID == kAudioFormatLinearPCM,
      asbd.mBytesPerFrame > 0,
      asbd.mFramesPerPacket > 0
    else { throw RecordingPCMSampleConverterError.unsupportedFormat }
    var format = Ldtx_Recording_Xpc_V1_PCMFormat()
    format.sampleRate = asbd.mSampleRate
    format.formatID = asbd.mFormatID
    format.formatFlags = asbd.mFormatFlags
    format.bytesPerPacket = asbd.mBytesPerPacket
    format.framesPerPacket = asbd.mFramesPerPacket
    format.bytesPerFrame = asbd.mBytesPerFrame
    format.channelsPerFrame = asbd.mChannelsPerFrame
    format.bitsPerChannel = asbd.mBitsPerChannel
    var record = Ldtx_Recording_Xpc_V1_AudioRingRecord()
    record.sequence = sequence
    record.format = format
    return record
  }

  public static func bufferRecord(
    from sampleBuffer: CMSampleBuffer,
    sequence: UInt64
  ) throws -> Ldtx_Recording_Xpc_V1_AudioRingRecord {
    guard sampleBuffer.presentationTimeStamp.isValid else {
      throw RecordingPCMSampleConverterError.invalidTiming
    }
    guard let blockBuffer = sampleBuffer.dataBuffer else {
      throw RecordingPCMSampleConverterError.missingData
    }
    let length = CMBlockBufferGetDataLength(blockBuffer)
    var data = Data(count: length)
    let status = data.withUnsafeMutableBytes { bytes in
      CMBlockBufferCopyDataBytes(
        blockBuffer,
        atOffset: 0,
        dataLength: length,
        destination: bytes.baseAddress!
      )
    }
    guard status == kCMBlockBufferNoErr else {
      throw RecordingPCMSampleConverterError.missingData
    }
    var buffer = Ldtx_Recording_Xpc_V1_PCMBuffer()
    buffer.presentationTime = mediaTime(sampleBuffer.presentationTimeStamp)
    buffer.duration = mediaTime(sampleBuffer.duration.isValid ? sampleBuffer.duration : .zero)
    buffer.sampleCount = UInt32(CMSampleBufferGetNumSamples(sampleBuffer))
    buffer.data = data
    var record = Ldtx_Recording_Xpc_V1_AudioRingRecord()
    record.sequence = sequence
    record.buffer = buffer
    return record
  }

  public static func sampleBuffer(
    format: Ldtx_Recording_Xpc_V1_PCMFormat,
    buffer: Ldtx_Recording_Xpc_V1_PCMBuffer
  ) throws -> CMSampleBuffer {
    guard format.formatID == kAudioFormatLinearPCM,
      format.bytesPerFrame > 0,
      buffer.sampleCount > 0,
      UInt64(format.bytesPerFrame) * UInt64(buffer.sampleCount) == UInt64(buffer.data.count)
    else { throw RecordingPCMSampleConverterError.unsupportedFormat }
    let description = try formatDescription(format)
    var blockBuffer: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: buffer.data.count,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: buffer.data.count,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
      throw RecordingPCMSampleConverterError.cannotCreateBlockBuffer(blockStatus)
    }
    let copyStatus = buffer.data.withUnsafeBytes {
      CMBlockBufferReplaceDataBytes(
        with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0,
        dataLength: $0.count)
    }
    guard copyStatus == kCMBlockBufferNoErr else {
      throw RecordingPCMSampleConverterError.cannotCreateBlockBuffer(copyStatus)
    }
    var timing = CMSampleTimingInfo(
      duration: cmTime(buffer.duration),
      presentationTimeStamp: cmTime(buffer.presentationTime),
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: description,
      sampleCount: Int(buffer.sampleCount),
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
      throw RecordingPCMSampleConverterError.cannotCreateSample(sampleStatus)
    }
    return sampleBuffer
  }

  public static func formatDescription(
    _ format: Ldtx_Recording_Xpc_V1_PCMFormat
  ) throws -> CMAudioFormatDescription {
    var asbd = AudioStreamBasicDescription(
      mSampleRate: format.sampleRate,
      mFormatID: format.formatID,
      mFormatFlags: format.formatFlags,
      mBytesPerPacket: format.bytesPerPacket,
      mFramesPerPacket: format.framesPerPacket,
      mBytesPerFrame: format.bytesPerFrame,
      mChannelsPerFrame: format.channelsPerFrame,
      mBitsPerChannel: format.bitsPerChannel,
      mReserved: 0
    )
    var description: CMAudioFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &asbd,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &description
    )
    guard formatStatus == noErr, let description else {
      throw RecordingPCMSampleConverterError.cannotCreateFormat(formatStatus)
    }
    return description
  }

  private static func mediaTime(_ time: CMTime) -> Ldtx_Recording_Xpc_V1_MediaTime {
    var value = Ldtx_Recording_Xpc_V1_MediaTime()
    value.value = time.value
    value.timescale = time.timescale
    return value
  }

  private static func cmTime(_ time: Ldtx_Recording_Xpc_V1_MediaTime) -> CMTime {
    CMTime(value: time.value, timescale: time.timescale)
  }
}
