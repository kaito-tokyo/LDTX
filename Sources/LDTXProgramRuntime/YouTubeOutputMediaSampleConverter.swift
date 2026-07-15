// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXYouTubeOutputProtocol

enum YouTubeOutputMediaSampleConverterError: Error, LocalizedError {
  case missingFormatDescription
  case unsupportedVideoFormat
  case missingDataBuffer
  case invalidTiming
  case unsupportedPCMFormat

  var errorDescription: String? {
    switch self {
    case .missingFormatDescription: "The media sample has no format description."
    case .unsupportedVideoFormat: "The video sample is not H.264/AVCC."
    case .missingDataBuffer: "The media sample has no contiguous data buffer."
    case .invalidTiming: "The media sample timing is invalid."
    case .unsupportedPCMFormat: "The audio sample is not interleaved Float32 PCM."
    }
  }
}

enum YouTubeOutputMediaSampleConverter {
  static func h264Format(from sampleBuffer: CMSampleBuffer) throws -> YouTubeOutputH264Format {
    guard let formatDescription = sampleBuffer.formatDescription else {
      throw YouTubeOutputMediaSampleConverterError.missingFormatDescription
    }
    guard CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_H264 else {
      throw YouTubeOutputMediaSampleConverterError.unsupportedVideoFormat
    }

    var parameterSetCount = 0
    var nalUnitHeaderLength: Int32 = 0
    let countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      formatDescription,
      parameterSetIndex: 0,
      parameterSetPointerOut: nil,
      parameterSetSizeOut: nil,
      parameterSetCountOut: &parameterSetCount,
      nalUnitHeaderLengthOut: &nalUnitHeaderLength
    )
    guard countStatus == noErr, parameterSetCount >= 2 else {
      throw YouTubeOutputMediaSampleConverterError.unsupportedVideoFormat
    }

    var parameterSets: [Data] = []
    for index in 0..<parameterSetCount {
      var pointer: UnsafePointer<UInt8>?
      var size = 0
      let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        formatDescription,
        parameterSetIndex: index,
        parameterSetPointerOut: &pointer,
        parameterSetSizeOut: &size,
        parameterSetCountOut: nil,
        nalUnitHeaderLengthOut: nil
      )
      guard status == noErr, let pointer, size > 0 else {
        throw YouTubeOutputMediaSampleConverterError.unsupportedVideoFormat
      }
      parameterSets.append(Data(bytes: pointer, count: size))
    }
    return YouTubeOutputH264Format(
      parameterSets: parameterSets,
      nalUnitHeaderLength: nalUnitHeaderLength,
      width: Int32(CMVideoFormatDescriptionGetDimensions(formatDescription).width),
      height: Int32(CMVideoFormatDescriptionGetDimensions(formatDescription).height)
    )
  }

  static func h264AccessUnit(
    from sampleBuffer: CMSampleBuffer
  ) throws -> YouTubeOutputH264AccessUnit {
    guard sampleBuffer.presentationTimeStamp.isValid else {
      throw YouTubeOutputMediaSampleConverterError.invalidTiming
    }
    let duration = sampleBuffer.duration.isValid ? sampleBuffer.duration : .zero
    let decodeTime =
      sampleBuffer.decodeTimeStamp.isValid
      ? mediaTime(sampleBuffer.decodeTimeStamp) : nil
    return YouTubeOutputH264AccessUnit(
      presentationTime: mediaTime(sampleBuffer.presentationTimeStamp),
      decodeTime: decodeTime,
      duration: mediaTime(duration),
      isKeyFrame: isKeyFrame(sampleBuffer),
      avccData: try data(from: sampleBuffer)
    )
  }

  static func pcmBuffer(from sampleBuffer: CMSampleBuffer) throws -> YouTubeOutputPCMBuffer {
    guard let formatDescription = sampleBuffer.formatDescription,
      let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?
        .pointee
    else {
      throw YouTubeOutputMediaSampleConverterError.missingFormatDescription
    }
    let requiredFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    guard description.mFormatID == kAudioFormatLinearPCM,
      description.mBitsPerChannel == 32,
      description.mFormatFlags & requiredFlags == requiredFlags,
      description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    else {
      throw YouTubeOutputMediaSampleConverterError.unsupportedPCMFormat
    }
    let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
    guard frameCount > 0, sampleBuffer.presentationTimeStamp.isValid else {
      throw YouTubeOutputMediaSampleConverterError.invalidTiming
    }
    let sampleRate = Int32(description.mSampleRate.rounded())
    return YouTubeOutputPCMBuffer(
      presentationTime: mediaTime(sampleBuffer.presentationTimeStamp),
      duration: YouTubeOutputMediaTime(value: Int64(frameCount), timescale: sampleRate),
      sampleRate: sampleRate,
      channelCount: Int32(description.mChannelsPerFrame),
      frameCount: Int32(clamping: frameCount),
      sampleFormat: .float32Interleaved,
      data: try data(from: sampleBuffer)
    )
  }

  private static func mediaTime(_ time: CMTime) -> YouTubeOutputMediaTime {
    YouTubeOutputMediaTime(value: time.value, timescale: time.timescale)
  }

  private static func data(from sampleBuffer: CMSampleBuffer) throws -> Data {
    guard let blockBuffer = sampleBuffer.dataBuffer else {
      throw YouTubeOutputMediaSampleConverterError.missingDataBuffer
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
      throw YouTubeOutputMediaSampleConverterError.missingDataBuffer
    }
    return data
  }

  private static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: false
      ) as? [[CFString: Any]],
      let first = attachments.first
    else { return true }
    return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
  }
}
