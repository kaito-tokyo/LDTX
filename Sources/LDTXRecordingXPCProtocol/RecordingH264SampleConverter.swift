// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation

public enum RecordingH264SampleConverterError: Error {
  case missingFormat
  case invalidFormat
  case missingData
  case invalidTiming
  case cannotCreateBlockBuffer(OSStatus)
  case cannotCreateFormat(OSStatus)
  case cannotCreateSample(OSStatus)
}

public enum RecordingH264SampleConverter {
  public static func formatRecord(
    from sampleBuffer: CMSampleBuffer,
    sequence: UInt64
  ) throws -> Ldtx_Recording_Xpc_V1_VideoRingRecord {
    guard let formatDescription = sampleBuffer.formatDescription else {
      throw RecordingH264SampleConverterError.missingFormat
    }
    var parameterSetCount = 0
    var nalUnitHeaderLength: Int32 = 0
    guard
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        formatDescription,
        parameterSetIndex: 0,
        parameterSetPointerOut: nil,
        parameterSetSizeOut: nil,
        parameterSetCountOut: &parameterSetCount,
        nalUnitHeaderLengthOut: &nalUnitHeaderLength
      ) == noErr, parameterSetCount >= 2
    else {
      throw RecordingH264SampleConverterError.invalidFormat
    }
    var format = Ldtx_Recording_Xpc_V1_H264Format()
    for index in 0..<parameterSetCount {
      var pointer: UnsafePointer<UInt8>?
      var size = 0
      guard
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
          formatDescription,
          parameterSetIndex: index,
          parameterSetPointerOut: &pointer,
          parameterSetSizeOut: &size,
          parameterSetCountOut: nil,
          nalUnitHeaderLengthOut: nil
        ) == noErr, let pointer, size > 0
      else {
        throw RecordingH264SampleConverterError.invalidFormat
      }
      format.parameterSets.append(Data(bytes: pointer, count: size))
    }
    let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
    format.nalUnitHeaderLength = nalUnitHeaderLength
    format.width = dimensions.width
    format.height = dimensions.height
    var record = Ldtx_Recording_Xpc_V1_VideoRingRecord()
    record.sequence = sequence
    record.format = format
    return record
  }

  public static func accessUnitRecord(
    from sampleBuffer: CMSampleBuffer,
    sequence: UInt64
  ) throws -> Ldtx_Recording_Xpc_V1_VideoRingRecord {
    guard sampleBuffer.presentationTimeStamp.isValid,
      let blockBuffer = sampleBuffer.dataBuffer
    else { throw RecordingH264SampleConverterError.invalidTiming }
    let length = CMBlockBufferGetDataLength(blockBuffer)
    var data = Data(count: length)
    guard
      data.withUnsafeMutableBytes({ bytes in
        CMBlockBufferCopyDataBytes(
          blockBuffer,
          atOffset: 0,
          dataLength: length,
          destination: bytes.baseAddress!
        )
      }) == kCMBlockBufferNoErr
    else {
      throw RecordingH264SampleConverterError.missingData
    }
    var unit = Ldtx_Recording_Xpc_V1_H264AccessUnit()
    unit.presentationTime = mediaTime(sampleBuffer.presentationTimeStamp)
    if sampleBuffer.decodeTimeStamp.isValid {
      unit.decodeTimePresent = true
      unit.decodeTime = mediaTime(sampleBuffer.decodeTimeStamp)
    }
    unit.duration = mediaTime(sampleBuffer.duration.isValid ? sampleBuffer.duration : .zero)
    unit.keyFrame = isKeyFrame(sampleBuffer)
    unit.avccData = data
    var record = Ldtx_Recording_Xpc_V1_VideoRingRecord()
    record.sequence = sequence
    record.accessUnit = unit
    return record
  }

  public static func sampleBuffer(
    format: Ldtx_Recording_Xpc_V1_H264Format,
    accessUnit: Ldtx_Recording_Xpc_V1_H264AccessUnit
  ) throws -> CMSampleBuffer {
    let parameterSets = format.parameterSets
    guard parameterSets.count >= 2 else { throw RecordingH264SampleConverterError.invalidFormat }
    var formatDescription: CMFormatDescription?
    let nsParameterSets = parameterSets.map { $0 as NSData }
    let formatStatus = nsParameterSets.withUnsafeBufferPointer { sets in
      let pointers = sets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
      let sizes = sets.map(\.length)
      return pointers.withUnsafeBufferPointer { pointerBuffer in
        sizes.withUnsafeBufferPointer { sizeBuffer in
          CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: sets.count,
            parameterSetPointers: pointerBuffer.baseAddress!,
            parameterSetSizes: sizeBuffer.baseAddress!,
            nalUnitHeaderLength: format.nalUnitHeaderLength,
            formatDescriptionOut: &formatDescription
          )
        }
      }
    }
    guard formatStatus == noErr, let formatDescription else {
      throw RecordingH264SampleConverterError.cannotCreateFormat(formatStatus)
    }

    var blockBuffer: CMBlockBuffer?
    let blockStatus = accessUnit.avccData.withUnsafeBytes { bytes in
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: bytes.count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: bytes.count,
        flags: 0,
        blockBufferOut: &blockBuffer
      )
    }
    guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
      throw RecordingH264SampleConverterError.cannotCreateBlockBuffer(blockStatus)
    }
    let copyStatus = accessUnit.avccData.withUnsafeBytes { bytes in
      CMBlockBufferReplaceDataBytes(
        with: bytes.baseAddress!,
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: bytes.count
      )
    }
    guard copyStatus == kCMBlockBufferNoErr else {
      throw RecordingH264SampleConverterError.cannotCreateBlockBuffer(copyStatus)
    }

    var timing = CMSampleTimingInfo(
      duration: cmTime(accessUnit.duration),
      presentationTimeStamp: cmTime(accessUnit.presentationTime),
      decodeTimeStamp: accessUnit.decodeTimePresent ? cmTime(accessUnit.decodeTime) : .invalid
    )
    var sampleSize = accessUnit.avccData.count
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: formatDescription,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
      throw RecordingH264SampleConverterError.cannotCreateSample(sampleStatus)
    }
    if !accessUnit.keyFrame,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: true
      ), CFArrayGetCount(attachments) > 0,
      let rawAttachment = CFArrayGetValueAtIndex(attachments, 0)
    {
      let attachment = unsafeBitCast(rawAttachment, to: CFMutableDictionary.self)
      CFDictionarySetValue(
        attachment,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }
    return sampleBuffer
  }

  private static func mediaTime(_ time: CMTime) -> Ldtx_Recording_Xpc_V1_MediaTime {
    var result = Ldtx_Recording_Xpc_V1_MediaTime()
    result.value = time.value
    result.timescale = time.timescale
    return result
  }

  private static func cmTime(_ time: Ldtx_Recording_Xpc_V1_MediaTime) -> CMTime {
    CMTime(value: time.value, timescale: time.timescale)
  }

  private static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: false
      ) as? [[CFString: Any]], let first = attachments.first
    else { return true }
    return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
  }
}
