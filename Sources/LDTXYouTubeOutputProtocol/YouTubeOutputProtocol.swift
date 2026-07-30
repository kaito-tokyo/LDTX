// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftProtobuf

@objc public protocol LDTXYouTubeOutputServiceProcessXPC {
  func bootstrap(
    _ request: Data,
    sharedVideoMemory: FileHandle,
    withReply reply: @escaping (Data) -> Void)
  func appendMediaBatch(_ request: Data, withReply reply: @escaping (Data) -> Void)
  func finish(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

@objc public protocol LDTXYouTubeOutputServiceProcessClientXPC {
  func serviceReservesCheckpoint(_ request: Data, withReply reply: @escaping (Data) -> Void)
  func serviceRequestsReset(_ request: Data)
  func serviceCommitsCheckpoint(_ request: Data)
  func serviceCommitsMediaCheckpoint(_ request: Data)
}

public enum LDTXYouTubeOutputServiceProcessInterfaces {
  public static var serviceName: String {
    Bundle.main.object(forInfoDictionaryKey: "LDTXYouTubeOutputServiceProcessXPCServiceName") as? String
      ?? "tokyo.kaito.ldtx.LDTX.YouTubeOutputServiceProcess"
  }
  public static let protocolVersion: UInt32 = 7

  public static func service() -> NSXPCInterface {
    NSXPCInterface(with: LDTXYouTubeOutputServiceProcessXPC.self)
  }

  public static func client() -> NSXPCInterface {
    NSXPCInterface(with: LDTXYouTubeOutputServiceProcessClientXPC.self)
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
  public var persistenceIdentifier: String
  public var nextMediaTimeSeconds: Double?
  public var sharedVideoSlotCount: Int
  public var sharedVideoSlotSize: Int

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
    initializationSegment: Data? = nil,
    persistenceIdentifier: String,
    nextMediaTimeSeconds: Double? = nil,
    sharedVideoSlotCount: Int = 0,
    sharedVideoSlotSize: Int = 0
  ) {
    protocolVersion = LDTXYouTubeOutputServiceProcessInterfaces.protocolVersion
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
    self.persistenceIdentifier = persistenceIdentifier
    self.nextMediaTimeSeconds = nextMediaTimeSeconds
    self.sharedVideoSlotCount = sharedVideoSlotCount
    self.sharedVideoSlotSize = sharedVideoSlotSize
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
  public var nextMediaTimeSeconds: Double?
  public init(
    context: YouTubeOutputContext,
    reason: String,
    nextMediaSegmentNumber: Int? = nil,
    initializationSegment: Data? = nil,
    configurationFingerprint: String? = nil,
    availabilityStartTime: Date? = nil,
    nextMediaTimeSeconds: Double? = nil
  ) {
    self.context = context
    self.reason = reason
    self.nextMediaSegmentNumber = nextMediaSegmentNumber
    self.initializationSegment = initializationSegment
    self.configurationFingerprint = configurationFingerprint
    self.availabilityStartTime = availabilityStartTime
    self.nextMediaTimeSeconds = nextMediaTimeSeconds
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
