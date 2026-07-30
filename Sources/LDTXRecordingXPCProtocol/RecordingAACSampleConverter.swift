// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreMedia
import Foundation
import LDTXOutputMedia

public enum RecordingAACSampleConverter {
  /// Serializes the common Program-output AAC contract.  Main Recording does
  /// not inspect or re-encode Program audio after the hub has encoded it.
  public static func formatRecord(from input: ProgramOutputAACFormat, sequence: UInt64) -> Ldtx_Recording_Xpc_V1_AACRingRecord {
    var format = Ldtx_Recording_Xpc_V1_AACFormat()
    format.sampleRate = input.sampleRate
    format.channelsPerFrame = UInt32(input.channelCount)
    format.magicCookie = input.magicCookie
    var record = Ldtx_Recording_Xpc_V1_AACRingRecord()
    record.sequence = sequence
    record.format = format
    return record
  }

  public static func accessUnitRecord(from input: ProgramOutputAACAccessUnit, sequence: UInt64) -> Ldtx_Recording_Xpc_V1_AACRingRecord {
    var unit = Ldtx_Recording_Xpc_V1_AACAccessUnit()
    unit.presentationTime = time(input.presentationTime)
    unit.duration = time(input.duration)
    unit.sampleCount = UInt32(input.sampleCount)
    unit.sampleSizes = input.sampleSizes.map(UInt32.init)
    unit.data = input.data
    var record = Ldtx_Recording_Xpc_V1_AACRingRecord()
    record.sequence = sequence
    record.accessUnit = unit
    return record
  }

  public static func formatRecord(from sample: CMSampleBuffer, sequence: UInt64) throws -> Ldtx_Recording_Xpc_V1_AACRingRecord {
    guard let description = sample.formatDescription,
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
      asbd.mFormatID == kAudioFormatMPEG4AAC else { throw Error.invalidFormat }
    var format = Ldtx_Recording_Xpc_V1_AACFormat(); format.sampleRate = asbd.mSampleRate; format.channelsPerFrame = asbd.mChannelsPerFrame
    var size = 0
    if let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size), size > 0 { format.magicCookie = Data(bytes: cookie, count: size) }
    var record = Ldtx_Recording_Xpc_V1_AACRingRecord(); record.sequence = sequence; record.format = format; return record
  }
  public static func accessUnitRecord(from sample: CMSampleBuffer, sequence: UInt64) throws -> Ldtx_Recording_Xpc_V1_AACRingRecord {
    guard let block = sample.dataBuffer, sample.presentationTimeStamp.isValid, sample.duration.isValid else { throw Error.invalidSample }
    let length = CMBlockBufferGetDataLength(block); var data = Data(count: length)
    guard data.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }) == noErr else { throw Error.invalidSample }
    let count = CMSampleBufferGetNumSamples(sample); guard count > 0 else { throw Error.invalidSample }
    var unit = Ldtx_Recording_Xpc_V1_AACAccessUnit(); unit.presentationTime = time(sample.presentationTimeStamp); unit.duration = time(sample.duration); unit.sampleCount = UInt32(count); unit.sampleSizes = (0..<count).map { UInt32(CMSampleBufferGetSampleSize(sample, at: $0)) }; unit.data = data
    var record = Ldtx_Recording_Xpc_V1_AACRingRecord(); record.sequence = sequence; record.accessUnit = unit; return record
  }
  public static func sampleBuffer(format: Ldtx_Recording_Xpc_V1_AACFormat, accessUnit: Ldtx_Recording_Xpc_V1_AACAccessUnit) throws -> CMSampleBuffer {
    guard accessUnit.sampleCount > 0, accessUnit.sampleSizes.count == Int(accessUnit.sampleCount), accessUnit.sampleSizes.reduce(0, { $0 + Int($1) }) == accessUnit.data.count else { throw Error.invalidSample }
    var asbd = AudioStreamBasicDescription(mSampleRate: format.sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: format.channelsPerFrame, mBitsPerChannel: 0, mReserved: 0); var description: CMAudioFormatDescription?
    let formatStatus = format.magicCookie.withUnsafeBytes { CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: $0.count, magicCookie: $0.baseAddress, extensions: nil, formatDescriptionOut: &description) }
    guard formatStatus == noErr, let description else { throw Error.status(formatStatus) }
    var block: CMBlockBuffer?; let blockStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: accessUnit.data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: accessUnit.data.count, flags: 0, blockBufferOut: &block)
    guard blockStatus == noErr, let block else { throw Error.status(blockStatus) }
    guard accessUnit.data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }) == noErr else { throw Error.invalidSample }
    var timing = CMSampleTimingInfo(duration: cmTime(accessUnit.duration), presentationTimeStamp: cmTime(accessUnit.presentationTime), decodeTimeStamp: .invalid); var sizes = accessUnit.sampleSizes.map(Int.init); var result: CMSampleBuffer?
    let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description, sampleCount: Int(accessUnit.sampleCount), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: sizes.count, sampleSizeArray: &sizes, sampleBufferOut: &result)
    guard status == noErr, let result else { throw Error.status(status) }; return result
  }
  private static func time(_ value: CMTime) -> Ldtx_Recording_Xpc_V1_MediaTime { var result = Ldtx_Recording_Xpc_V1_MediaTime(); result.value = value.value; result.timescale = value.timescale; return result }
  private static func time(_ value: ProgramOutputMediaTime) -> Ldtx_Recording_Xpc_V1_MediaTime { var result = Ldtx_Recording_Xpc_V1_MediaTime(); result.value = value.value; result.timescale = value.timescale; return result }
  private static func cmTime(_ value: Ldtx_Recording_Xpc_V1_MediaTime) -> CMTime { CMTime(value: value.value, timescale: value.timescale) }
  public enum Error: Swift.Error { case invalidFormat, invalidSample, status(OSStatus) }
}
