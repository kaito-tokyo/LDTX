// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreMedia
import Foundation

/// A deep PCM copy whose data buffer is owned by the downstream media stage.
///
/// Capture callbacks may borrow their sample buffer only synchronously.  Use
/// this type before retaining PCM in an escaping closure or crossing queues.
public struct ProgramOwnedPCMSampleBuffer: @unchecked Sendable {
  public let value: CMSampleBuffer

  public init(copying source: CMSampleBuffer) throws {
    guard let formatDescription = source.formatDescription,
      let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?
        .pointee,
      streamDescription.mFormatID == kAudioFormatLinearPCM
    else {
      throw ProgramOwnedPCMSampleBufferError.missingPCMFormat
    }
    guard let sourceDataBuffer = source.dataBuffer else {
      throw ProgramOwnedPCMSampleBufferError.missingDataBuffer
    }
    let dataLength = CMBlockBufferGetDataLength(sourceDataBuffer)
    guard dataLength > 0 else { throw ProgramOwnedPCMSampleBufferError.missingDataBuffer }

    var timingEntryCount = 0
    let timingCountStatus = CMSampleBufferGetSampleTimingInfoArray(
      source, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingEntryCount)
    guard timingCountStatus == noErr, timingEntryCount > 0 else {
      throw ProgramOwnedPCMSampleBufferError.invalidTiming(timingCountStatus)
    }
    var timings = Array(repeating: CMSampleTimingInfo(), count: timingEntryCount)
    let timingStatus = timings.withUnsafeMutableBufferPointer {
      CMSampleBufferGetSampleTimingInfoArray(
        source, entryCount: timingEntryCount, arrayToFill: $0.baseAddress, entriesNeededOut: nil)
    }
    guard timingStatus == noErr else {
      throw ProgramOwnedPCMSampleBufferError.invalidTiming(timingStatus)
    }

    var data = Data(count: dataLength)
    let copyStatus = data.withUnsafeMutableBytes {
      CMBlockBufferCopyDataBytes(
        sourceDataBuffer, atOffset: 0, dataLength: dataLength, destination: $0.baseAddress!)
    }
    guard copyStatus == kCMBlockBufferNoErr else {
      throw ProgramOwnedPCMSampleBufferError.dataCopyFailed(copyStatus)
    }

    var ownedDataBuffer: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: dataLength,
      blockAllocator: nil,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: dataLength,
      flags: 0,
      blockBufferOut: &ownedDataBuffer)
    guard blockStatus == kCMBlockBufferNoErr, let ownedDataBuffer else {
      throw ProgramOwnedPCMSampleBufferError.blockBufferCreationFailed(blockStatus)
    }
    let replaceStatus = data.withUnsafeBytes {
      CMBlockBufferReplaceDataBytes(
        with: $0.baseAddress!, blockBuffer: ownedDataBuffer, offsetIntoDestination: 0,
        dataLength: dataLength)
    }
    guard replaceStatus == kCMBlockBufferNoErr else {
      throw ProgramOwnedPCMSampleBufferError.dataCopyFailed(replaceStatus)
    }

    var copied: CMSampleBuffer?
    let sampleStatus = timings.withUnsafeMutableBufferPointer {
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: ownedDataBuffer,
        formatDescription: formatDescription,
        sampleCount: CMSampleBufferGetNumSamples(source),
        sampleTimingEntryCount: timingEntryCount,
        sampleTimingArray: $0.baseAddress,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &copied)
    }
    guard sampleStatus == noErr, let copied else {
      throw ProgramOwnedPCMSampleBufferError.sampleBufferCreationFailed(sampleStatus)
    }
    value = copied
  }
}

private enum ProgramOwnedPCMSampleBufferError: Error, LocalizedError {
  case missingPCMFormat
  case missingDataBuffer
  case invalidTiming(OSStatus)
  case blockBufferCreationFailed(OSStatus)
  case dataCopyFailed(OSStatus)
  case sampleBufferCreationFailed(OSStatus)

  var errorDescription: String? {
    switch self {
    case .missingPCMFormat: "The captured audio sample is not linear PCM."
    case .missingDataBuffer: "The captured audio sample has no data buffer."
    case .invalidTiming(let status): "The captured audio timing could not be copied: \(status)."
    case .blockBufferCreationFailed(let status):
      "The owned PCM block buffer could not be created: \(status)."
    case .dataCopyFailed(let status): "The captured PCM data could not be copied: \(status)."
    case .sampleBufferCreationFailed(let status):
      "The owned PCM sample buffer could not be created: \(status)."
    }
  }
}
