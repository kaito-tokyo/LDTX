// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct YouTubeOutputMediaTime: Equatable, Sendable {
  public var value: Int64
  public var timescale: Int32

  public init(value: Int64, timescale: Int32) {
    self.value = value
    self.timescale = timescale
  }
}

public struct YouTubeOutputH264Format: Equatable, Sendable {
  public var parameterSets: [Data]
  public var nalUnitHeaderLength: Int32
  public var width: Int32
  public var height: Int32

  public init(parameterSets: [Data], nalUnitHeaderLength: Int32, width: Int32, height: Int32) {
    self.parameterSets = parameterSets
    self.nalUnitHeaderLength = nalUnitHeaderLength
    self.width = width
    self.height = height
  }
}

extension YouTubeOutputH264Format {
  /// RFC 6381 AVC codec identifier derived from the SPS carried with the
  /// encoded stream. The manifest must use this value rather than assuming
  /// that every VideoToolbox implementation emits identical constraint flags.
  public var codecString: String? {
    guard let sps = parameterSets.first(where: { $0.count >= 4 && $0[0] & 0x1F == 7 }) else {
      return nil
    }
    return String(format: "avc1.%02x%02x%02x", sps[1], sps[2], sps[3])
  }
}

public struct YouTubeOutputH264AccessUnit: Equatable, Sendable {
  public var presentationTime: YouTubeOutputMediaTime
  public var decodeTime: YouTubeOutputMediaTime?
  public var duration: YouTubeOutputMediaTime
  public var isKeyFrame: Bool
  public var avccData: Data
  public var sharedMemory: YouTubeOutputSharedMemorySlice?

  public init(
    presentationTime: YouTubeOutputMediaTime,
    decodeTime: YouTubeOutputMediaTime?,
    duration: YouTubeOutputMediaTime,
    isKeyFrame: Bool,
    avccData: Data,
    sharedMemory: YouTubeOutputSharedMemorySlice? = nil
  ) {
    self.presentationTime = presentationTime
    self.decodeTime = decodeTime
    self.duration = duration
    self.isKeyFrame = isKeyFrame
    self.avccData = avccData
    self.sharedMemory = sharedMemory
  }
}

public struct YouTubeOutputSharedMemorySlice: Equatable, Sendable {
  public var slot: Int
  public var generation: UInt64
  public var offset: Int
  public var length: Int

  public init(slot: Int, generation: UInt64, offset: Int, length: Int) {
    self.slot = slot
    self.generation = generation
    self.offset = offset
    self.length = length
  }
}

public enum YouTubeOutputPCMSampleFormat: Equatable, Sendable {
  case float32Interleaved
}

public struct YouTubeOutputPCMBuffer: Equatable, Sendable {
  public var presentationTime: YouTubeOutputMediaTime
  public var duration: YouTubeOutputMediaTime
  public var sampleRate: Int32
  public var channelCount: Int32
  public var frameCount: Int32
  public var sampleFormat: YouTubeOutputPCMSampleFormat
  public var data: Data

  public init(
    presentationTime: YouTubeOutputMediaTime,
    duration: YouTubeOutputMediaTime,
    sampleRate: Int32,
    channelCount: Int32,
    frameCount: Int32,
    sampleFormat: YouTubeOutputPCMSampleFormat,
    data: Data
  ) {
    self.presentationTime = presentationTime
    self.duration = duration
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.frameCount = frameCount
    self.sampleFormat = sampleFormat
    self.data = data
  }
}

public struct YouTubeOutputMediaBatch: Equatable, Sendable {
  public var protocolVersion: UInt32
  public var context: YouTubeOutputContext
  public var sequence: UInt64
  public var videoFormat: YouTubeOutputH264Format?
  public var video: [YouTubeOutputH264AccessUnit]
  public var audio: [YouTubeOutputPCMBuffer]

  public init(
    context: YouTubeOutputContext,
    sequence: UInt64,
    videoFormat: YouTubeOutputH264Format? = nil,
    video: [YouTubeOutputH264AccessUnit] = [],
    audio: [YouTubeOutputPCMBuffer] = []
  ) {
    protocolVersion = LDTXYouTubeOutputServiceProcessInterfaces.protocolVersion
    self.context = context
    self.sequence = sequence
    self.videoFormat = videoFormat
    self.video = video
    self.audio = audio
  }
}

public enum YouTubeOutputMessageError: Error, LocalizedError {
  case invalidSessionID(String)
  case invalidURL(String)
  case unsupportedPCMSampleFormat

  public var errorDescription: String? {
    switch self {
    case .invalidSessionID(let value): "Invalid output session ID: \(value)"
    case .invalidURL(let value): "Invalid output endpoint URL: \(value)"
    case .unsupportedPCMSampleFormat: "The PCM sample format is unsupported."
    }
  }
}
