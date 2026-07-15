// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftProtobuf

@objc public protocol LDTXYouTubeOutputServiceXPC {
  func bootstrap(_ request: Data, withReply reply: @escaping (Data) -> Void)
  func appendMediaBatch(_ request: Data, withReply reply: @escaping (Data) -> Void)
  func finish(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

@objc public protocol LDTXYouTubeOutputServiceClientXPC {
  func serviceRequestsReset(_ request: Data)
  func serviceCommitsCheckpoint(_ request: Data)
}

public enum LDTXYouTubeOutputServiceInterfaces {
  public static let serviceName = "tokyo.kaito.ldtx.LDTX.YouTubeOutputService"
  public static let protocolVersion: UInt32 = 4

  public static func service() -> NSXPCInterface {
    NSXPCInterface(with: LDTXYouTubeOutputServiceXPC.self)
  }

  public static func client() -> NSXPCInterface {
    NSXPCInterface(with: LDTXYouTubeOutputServiceClientXPC.self)
  }
}

public struct YouTubeOutputContext: Codable, Equatable, Hashable, Sendable {
  public var sessionID: UUID
  public var generation: UInt64

  public init(sessionID: UUID, generation: UInt64) {
    self.sessionID = sessionID
    self.generation = generation
  }
}

public struct YouTubeOutputBootstrap: Codable, Equatable, Sendable {
  public var protocolVersion: UInt32
  public var context: YouTubeOutputContext
  public var endpoint: URL
  public var availabilityStartTime: Date
  public var timescale: Int
  public var segmentDurationSeconds: Int
  public var startNumber: Int
  public var mediaTemplate: String
  public var representation: YouTubeOutputRepresentation
  public var configurationFingerprint: String
  public var initializationSegment: Data?

  public init(
    context: YouTubeOutputContext,
    endpoint: URL,
    availabilityStartTime: Date,
    timescale: Int,
    segmentDurationSeconds: Int,
    startNumber: Int,
    mediaTemplate: String,
    representation: YouTubeOutputRepresentation,
    configurationFingerprint: String,
    initializationSegment: Data? = nil
  ) {
    protocolVersion = LDTXYouTubeOutputServiceInterfaces.protocolVersion
    self.context = context
    self.endpoint = endpoint
    self.availabilityStartTime = availabilityStartTime
    self.timescale = timescale
    self.segmentDurationSeconds = segmentDurationSeconds
    self.startNumber = startNumber
    self.mediaTemplate = mediaTemplate
    self.representation = representation
    self.configurationFingerprint = configurationFingerprint
    self.initializationSegment = initializationSegment
  }
}

public struct YouTubeOutputRepresentation: Codable, Equatable, Sendable {
  public var id: String
  public var bandwidth: Int
  public var width: Int
  public var height: Int
  public var frameRate: String
  public var codecs: String
  public var audioSamplingRate: Int

  public init(
    id: String, bandwidth: Int, width: Int, height: Int, frameRate: String, codecs: String,
    audioSamplingRate: Int
  ) {
    self.id = id
    self.bandwidth = bandwidth
    self.width = width
    self.height = height
    self.frameRate = frameRate
    self.codecs = codecs
    self.audioSamplingRate = audioSamplingRate
  }
}

public struct YouTubeOutputFinishRequest: Codable, Equatable, Sendable {
  public var context: YouTubeOutputContext
  public init(context: YouTubeOutputContext) { self.context = context }
}

public struct YouTubeOutputReply: Codable, Equatable, Sendable {
  public var context: YouTubeOutputContext
  public var sequence: UInt64?
  public var nextMediaSegmentNumber: Int?
  public var initializationSegment: Data?
  public var configurationFingerprint: String?
  public var availabilityStartTime: Date?
  public var eventDescription: String?
  public var errorDescription: String?

  public init(
    context: YouTubeOutputContext, sequence: UInt64? = nil, nextMediaSegmentNumber: Int? = nil,
    initializationSegment: Data? = nil, configurationFingerprint: String? = nil,
    availabilityStartTime: Date? = nil,
    eventDescription: String? = nil,
    errorDescription: String? = nil
  ) {
    self.context = context
    self.sequence = sequence
    self.nextMediaSegmentNumber = nextMediaSegmentNumber
    self.initializationSegment = initializationSegment
    self.configurationFingerprint = configurationFingerprint
    self.availabilityStartTime = availabilityStartTime
    self.eventDescription = eventDescription
    self.errorDescription = errorDescription
  }
}

public struct YouTubeOutputResetRequest: Codable, Equatable, Sendable {
  public var context: YouTubeOutputContext
  public var reason: String
  public var nextMediaSegmentNumber: Int?
  public var initializationSegment: Data?
  public var configurationFingerprint: String?
  public var availabilityStartTime: Date?
  public init(
    context: YouTubeOutputContext,
    reason: String,
    nextMediaSegmentNumber: Int? = nil,
    initializationSegment: Data? = nil,
    configurationFingerprint: String? = nil,
    availabilityStartTime: Date? = nil
  ) {
    self.context = context
    self.reason = reason
    self.nextMediaSegmentNumber = nextMediaSegmentNumber
    self.initializationSegment = initializationSegment
    self.configurationFingerprint = configurationFingerprint
    self.availabilityStartTime = availabilityStartTime
  }
}

public protocol YouTubeOutputWireMessage {
  associatedtype Proto: SwiftProtobuf.Message
  init(proto: Proto) throws
  func makeProto() -> Proto
}

public enum YouTubeOutputCoding {
  public static func encode<T: YouTubeOutputWireMessage>(_ value: T) throws -> Data {
    try value.makeProto().serializedData()
  }

  public static func decode<T: YouTubeOutputWireMessage>(_ type: T.Type, from data: Data) throws
    -> T
  {
    try T(proto: T.Proto(serializedBytes: data))
  }
}
