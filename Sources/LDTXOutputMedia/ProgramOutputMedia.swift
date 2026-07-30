// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreMedia
import Foundation

/// A compressed access-unit contract shared by every Program output consumer.
///
/// The Program runtime encodes Program audio once and fans these values out to
/// YouTube and Main Recording.  Consumer-specific wire protocols only serialize
/// this contract; they must not independently reinterpret PCM input.
public struct ProgramOutputMediaTime: Equatable, Sendable {
  public var value: Int64
  public var timescale: Int32
  public init(value: Int64, timescale: Int32) { self.value = value; self.timescale = timescale }
}

public struct ProgramOutputH264Format: Equatable, Sendable {
  public var parameterSets: [Data]
  public var nalUnitHeaderLength: Int32
  public var width: Int32
  public var height: Int32
  public init(parameterSets: [Data], nalUnitHeaderLength: Int32, width: Int32, height: Int32) {
    self.parameterSets = parameterSets; self.nalUnitHeaderLength = nalUnitHeaderLength
    self.width = width; self.height = height
  }
}

public struct ProgramOutputH264AccessUnit: Equatable, Sendable {
  public var presentationTime: ProgramOutputMediaTime
  public var decodeTime: ProgramOutputMediaTime?
  public var duration: ProgramOutputMediaTime
  public var isKeyFrame: Bool
  public var avccData: Data
  public init(presentationTime: ProgramOutputMediaTime, decodeTime: ProgramOutputMediaTime?, duration: ProgramOutputMediaTime, isKeyFrame: Bool, avccData: Data) {
    self.presentationTime = presentationTime; self.decodeTime = decodeTime; self.duration = duration
    self.isKeyFrame = isKeyFrame; self.avccData = avccData
  }
}

public struct ProgramOutputAACFormat: Equatable, Sendable {
  public var sampleRate: Double
  public var channelCount: Int32
  public var magicCookie: Data
  public init(sampleRate: Double, channelCount: Int32, magicCookie: Data) {
    self.sampleRate = sampleRate; self.channelCount = channelCount; self.magicCookie = magicCookie
  }
}

public struct ProgramOutputAACAccessUnit: Equatable, Sendable {
  public var presentationTime: ProgramOutputMediaTime
  public var duration: ProgramOutputMediaTime
  public var sampleCount: Int32
  public var sampleSizes: [Int32]
  public var data: Data
  public init(presentationTime: ProgramOutputMediaTime, duration: ProgramOutputMediaTime, sampleCount: Int32, sampleSizes: [Int32], data: Data) {
    self.presentationTime = presentationTime; self.duration = duration; self.sampleCount = sampleCount
    self.sampleSizes = sampleSizes; self.data = data
  }
}

/// One compressed Program-audio packet produced by the shared AAC encoder.
///
/// This is the fan-out boundary for Program output.  Consumers such as
/// YouTube and Main Recording serialize this value; they must not receive or
/// encode the PCM Program mix independently.
public struct ProgramOutputAACPacket: Equatable, Sendable {
  public var format: ProgramOutputAACFormat
  public var accessUnit: ProgramOutputAACAccessUnit

  public init(format: ProgramOutputAACFormat, accessUnit: ProgramOutputAACAccessUnit) {
    self.format = format
    self.accessUnit = accessUnit
  }
}

public enum ProgramOutputMediaSampleConverterError: Error, LocalizedError {
  case missingFormatDescription, unsupportedVideoFormat, unsupportedAACFormat, missingDataBuffer, invalidTiming
  public var errorDescription: String? {
    switch self {
    case .missingFormatDescription: "The media sample has no format description."
    case .unsupportedVideoFormat: "The video sample is not H.264/AVCC."
    case .unsupportedAACFormat: "The audio sample is not AAC."
    case .missingDataBuffer: "The media sample has no contiguous data buffer."
    case .invalidTiming: "The media sample timing is invalid."
    }
  }
}

public enum ProgramOutputMediaSampleConverter {
  public static func h264Format(from sample: CMSampleBuffer) throws -> ProgramOutputH264Format {
    guard let description = sample.formatDescription else { throw ProgramOutputMediaSampleConverterError.missingFormatDescription }
    guard CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_H264 else { throw ProgramOutputMediaSampleConverterError.unsupportedVideoFormat }
    var count = 0; var headerLength: Int32 = 0
    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength) == noErr, count >= 2 else { throw ProgramOutputMediaSampleConverterError.unsupportedVideoFormat }
    var parameterSets: [Data] = []
    for index in 0..<count {
      var pointer: UnsafePointer<UInt8>?; var size = 0
      guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer, size > 0 else { throw ProgramOutputMediaSampleConverterError.unsupportedVideoFormat }
      parameterSets.append(Data(bytes: pointer, count: size))
    }
    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
    return ProgramOutputH264Format(parameterSets: parameterSets, nalUnitHeaderLength: headerLength, width: Int32(dimensions.width), height: Int32(dimensions.height))
  }

  public static func h264AccessUnit(from sample: CMSampleBuffer) throws -> ProgramOutputH264AccessUnit {
    guard sample.presentationTimeStamp.isValid else { throw ProgramOutputMediaSampleConverterError.invalidTiming }
    return ProgramOutputH264AccessUnit(presentationTime: time(sample.presentationTimeStamp), decodeTime: sample.decodeTimeStamp.isValid ? time(sample.decodeTimeStamp) : nil, duration: time(sample.duration.isValid ? sample.duration : .zero), isKeyFrame: isKeyFrame(sample), avccData: try data(from: sample))
  }

  public static func aacFormat(from sample: CMSampleBuffer) throws -> ProgramOutputAACFormat {
    guard let description = sample.formatDescription, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee, asbd.mFormatID == kAudioFormatMPEG4AAC else { throw ProgramOutputMediaSampleConverterError.unsupportedAACFormat }
    var size = 0; let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size)
    return ProgramOutputAACFormat(sampleRate: asbd.mSampleRate, channelCount: Int32(asbd.mChannelsPerFrame), magicCookie: cookie.map { Data(bytes: $0, count: size) } ?? Data())
  }

  public static func aacAccessUnit(from sample: CMSampleBuffer) throws -> ProgramOutputAACAccessUnit {
    let count = CMSampleBufferGetNumSamples(sample)
    guard count > 0, sample.presentationTimeStamp.isValid, sample.duration.isValid else { throw ProgramOutputMediaSampleConverterError.invalidTiming }
    return ProgramOutputAACAccessUnit(presentationTime: time(sample.presentationTimeStamp), duration: time(sample.duration), sampleCount: Int32(count), sampleSizes: (0..<count).map { Int32(CMSampleBufferGetSampleSize(sample, at: $0)) }, data: try data(from: sample))
  }

  public static func makeAACSample(
    accessUnit: ProgramOutputAACAccessUnit,
    format inputFormat: ProgramOutputAACFormat
  ) throws -> CMSampleBuffer {
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
      accessUnit.sampleCount > 0,
      accessUnit.sampleSizes.count == Int(accessUnit.sampleCount),
      accessUnit.sampleSizes.reduce(0, { $0 + Int($1) }) == accessUnit.data.count
    else { throw ProgramOutputMediaSampleConverterError.unsupportedAACFormat }
    var asbd = AudioStreamBasicDescription(
      mSampleRate: inputFormat.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
      mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
      mBytesPerFrame: 0, mChannelsPerFrame: UInt32(inputFormat.channelCount),
      mBitsPerChannel: 0, mReserved: 0)
    var description: CMAudioFormatDescription?
    let formatStatus = inputFormat.magicCookie.withUnsafeBytes {
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: $0.count, magicCookie: $0.baseAddress, extensions: nil,
        formatDescriptionOut: &description)
    }
    guard formatStatus == noErr, let description else {
      throw ProgramOutputMediaSampleConverterError.unsupportedAACFormat
    }
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: accessUnit.data.count,
      blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
      dataLength: accessUnit.data.count, flags: 0, blockBufferOut: &block) == noErr,
      let block,
      accessUnit.data.withUnsafeBytes({
        CMBlockBufferReplaceDataBytes(
          with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
          dataLength: $0.count)
      }) == noErr
    else { throw ProgramOutputMediaSampleConverterError.missingDataBuffer }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: CMTimeValue(accessUnit.duration.value), timescale: CMTimeScale(accessUnit.duration.timescale)),
      presentationTimeStamp: CMTime(value: CMTimeValue(accessUnit.presentationTime.value), timescale: CMTimeScale(accessUnit.presentationTime.timescale)),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
      sampleCount: Int(accessUnit.sampleCount), sampleTimingEntryCount: 1,
      sampleTimingArray: &timing, sampleSizeEntryCount: accessUnit.sampleSizes.count,
      sampleSizeArray: accessUnit.sampleSizes.map(Int.init), sampleBufferOut: &sample) == noErr,
      let sample
    else { throw ProgramOutputMediaSampleConverterError.invalidTiming }
    return sample
  }

  private static func time(_ value: CMTime) -> ProgramOutputMediaTime { ProgramOutputMediaTime(value: value.value, timescale: value.timescale) }
  private static func data(from sample: CMSampleBuffer) throws -> Data {
    guard let block = sample.dataBuffer else { throw ProgramOutputMediaSampleConverterError.missingDataBuffer }
    let length = CMBlockBufferGetDataLength(block); var result = Data(count: length)
    guard result.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }) == kCMBlockBufferNoErr else { throw ProgramOutputMediaSampleConverterError.missingDataBuffer }
    return result
  }
  private static func isKeyFrame(_ sample: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]], let first = attachments.first else { return true }
    return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
  }
}
