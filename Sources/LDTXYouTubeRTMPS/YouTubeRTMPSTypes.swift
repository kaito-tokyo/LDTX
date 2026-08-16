// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct YouTubeRTMPSDestination: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let ingestionURL: URL
  public let streamName: String

  public init(ingestionURL: URL, streamName: String) throws {
    guard ingestionURL.scheme?.lowercased() == "rtmps",
      ingestionURL.host != nil,
      ingestionURL.port == nil || ingestionURL.port == 443,
      ingestionURL.path.split(separator: "/").count == 1,
      !streamName.isEmpty
    else { throw YouTubeRTMPSError.invalidDestination }
    self.ingestionURL = ingestionURL
    self.streamName = streamName
  }

  public var description: String { "YouTubeRTMPSDestination(<redacted>)" }
  public var debugDescription: String { description }
}

public struct YouTubeRTMPSTime: Sendable, Equatable {
  public var milliseconds: Int64

  public init(milliseconds: Int64) {
    self.milliseconds = milliseconds
  }
}

public struct YouTubeRTMPSVideoFormat: Sendable, Equatable {
  public var sequenceParameterSet: Data
  public var pictureParameterSet: Data
  public var nalUnitHeaderLength: Int

  public init(
    sequenceParameterSet: Data,
    pictureParameterSet: Data,
    nalUnitHeaderLength: Int = 4
  ) {
    self.sequenceParameterSet = sequenceParameterSet
    self.pictureParameterSet = pictureParameterSet
    self.nalUnitHeaderLength = nalUnitHeaderLength
  }
}

public struct YouTubeRTMPSVideoSample: Sendable, Equatable {
  public var avccData: Data
  public var presentationTime: YouTubeRTMPSTime
  public var decodeTime: YouTubeRTMPSTime
  public var isKeyFrame: Bool

  public init(
    avccData: Data,
    presentationTime: YouTubeRTMPSTime,
    decodeTime: YouTubeRTMPSTime,
    isKeyFrame: Bool
  ) {
    self.avccData = avccData
    self.presentationTime = presentationTime
    self.decodeTime = decodeTime
    self.isKeyFrame = isKeyFrame
  }
}

public struct YouTubeRTMPSAudioFormat: Sendable, Equatable {
  public var audioSpecificConfig: Data

  public init(audioSpecificConfig: Data) {
    self.audioSpecificConfig = audioSpecificConfig
  }
}

public struct YouTubeRTMPSAudioSample: Sendable, Equatable {
  public var rawAACData: Data
  public var presentationTime: YouTubeRTMPSTime

  public init(rawAACData: Data, presentationTime: YouTubeRTMPSTime) {
    self.rawAACData = rawAACData
    self.presentationTime = presentationTime
  }
}

public enum YouTubeRTMPSPublisherState: Sendable, Equatable {
  case idle
  case connecting
  case publishing
  case reconnecting(attempt: Int)
  case stopped
}

public enum YouTubeRTMPSError: Error, LocalizedError, Equatable {
  case invalidDestination
  case invalidVideoFormat
  case invalidTimestamp
  case protocolFailure(String)
  case connectionFailed
  case queueLimitExceeded
  case notPublishing

  public var errorDescription: String? {
    switch self {
    case .invalidDestination: "The YouTube RTMPS destination is invalid."
    case .invalidVideoFormat: "The H.264 format cannot be sent to YouTube RTMPS."
    case .invalidTimestamp: "A media timestamp cannot be represented by RTMP."
    case .protocolFailure(let phase): "The YouTube RTMPS protocol failed during \(phase)."
    case .connectionFailed: "The secure connection to YouTube RTMPS failed."
    case .queueLimitExceeded: "The YouTube RTMPS media queue exceeded its limit."
    case .notPublishing: "The YouTube RTMPS publisher is not connected."
    }
  }
}
