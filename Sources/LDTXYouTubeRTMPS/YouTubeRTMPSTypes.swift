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
  public var width: Int
  public var height: Int
  public var frameRate: Double
  public var bitRate: Int

  public init(
    sequenceParameterSet: Data,
    pictureParameterSet: Data,
    nalUnitHeaderLength: Int = 4,
    width: Int = 0,
    height: Int = 0,
    frameRate: Double = 0,
    bitRate: Int = 0
  ) {
    self.sequenceParameterSet = sequenceParameterSet
    self.pictureParameterSet = pictureParameterSet
    self.nalUnitHeaderLength = nalUnitHeaderLength
    self.width = width
    self.height = height
    self.frameRate = frameRate
    self.bitRate = bitRate
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
  public var sampleRate: Double
  public var channelCount: Int
  public var bitRate: Int

  public init(
    audioSpecificConfig: Data,
    sampleRate: Double = 0,
    channelCount: Int = 0,
    bitRate: Int = 0
  ) {
    self.audioSpecificConfig = audioSpecificConfig
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.bitRate = bitRate
  }
}

public enum YouTubeRTMPSPublisherEvent: Sendable, Equatable {
  case formatDetected(String)
  case connecting
  case transportConnected
  case handshakeCompleted
  case commandCompleted(String)
  case metadataSent
  case videoSequenceHeaderSent
  case firstVideoKeyFrameSent
  case audioSequenceHeaderSent
  case firstAudioSampleSent
  case reconnecting(attempt: Int)
  case stopped

  public var logDescription: String {
    switch self {
    case .formatDetected(let description): "format detected: \(description)"
    case .connecting: "connecting"
    case .transportConnected: "secure transport connected"
    case .handshakeCompleted: "handshake completed"
    case .commandCompleted(let command): "\(command) completed"
    case .metadataSent: "metadata sent"
    case .videoSequenceHeaderSent: "video sequence header sent"
    case .firstVideoKeyFrameSent: "first video key frame sent"
    case .audioSequenceHeaderSent: "audio sequence header sent"
    case .firstAudioSampleSent: "first audio sample sent"
    case .reconnecting(let attempt): "reconnecting attempt \(attempt)"
    case .stopped: "stopped"
    }
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
