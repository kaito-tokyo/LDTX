// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension YouTubeOutputContext: YouTubeOutputWireMessage {
  public init(proto: Ldtx_YoutubeOutput_V1_Context) throws {
    guard let sessionID = UUID(uuidString: proto.sessionID) else {
      throw YouTubeOutputMessageError.invalidSessionID(proto.sessionID)
    }
    self.init(sessionID: sessionID, generation: proto.generation)
  }

  public func makeProto() -> Ldtx_YoutubeOutput_V1_Context {
    var proto = Ldtx_YoutubeOutput_V1_Context()
    proto.sessionID = sessionID.uuidString
    proto.generation = generation
    return proto
  }
}

extension YouTubeOutputRepresentation: YouTubeOutputWireMessage {
  public init(proto: Ldtx_YoutubeOutput_V1_Representation) throws {
    self.init(
      id: proto.id,
      bandwidth: Int(proto.bandwidth),
      width: Int(proto.width),
      height: Int(proto.height),
      frameRate: proto.frameRate,
      codecs: proto.codecs,
      audioSamplingRate: Int(proto.audioSamplingRate)
    )
  }

  public func makeProto() -> Ldtx_YoutubeOutput_V1_Representation {
    var proto = Ldtx_YoutubeOutput_V1_Representation()
    proto.id = id
    proto.bandwidth = Int32(clamping: bandwidth)
    proto.width = Int32(clamping: width)
    proto.height = Int32(clamping: height)
    proto.frameRate = frameRate
    proto.codecs = codecs
    proto.audioSamplingRate = Int32(clamping: audioSamplingRate)
    return proto
  }
}

extension YouTubeOutputBootstrap: YouTubeOutputWireMessage {
  public init(proto: Ldtx_YoutubeOutput_V1_Bootstrap) throws {
    guard let endpoint = URL(string: proto.endpoint) else {
      throw YouTubeOutputMessageError.invalidURL(proto.endpoint)
    }
    self.init(
      context: try YouTubeOutputContext(proto: proto.context),
      endpoint: endpoint,
      availabilityStartTime: Date(
        timeIntervalSince1970: Double(proto.availabilityStartTimeMilliseconds) / 1_000),
      timescale: Int(proto.timescale),
      segmentDurationSeconds: Int(proto.segmentDurationSeconds),
      startNumber: Int(proto.startNumber),
      mediaTemplate: proto.mediaTemplate,
      representation: try YouTubeOutputRepresentation(proto: proto.representation),
      configurationFingerprint: proto.configurationFingerprint,
      initializationSegment: proto.hasInitializationSegment ? proto.initializationSegment : nil,
      persistenceIdentifier: proto.persistenceIdentifier,
      nextMediaTimeSeconds: proto.hasNextMediaTimeSeconds ? proto.nextMediaTimeSeconds : nil
    )
    protocolVersion = proto.protocolVersion
  }

  public func makeProto() -> Ldtx_YoutubeOutput_V1_Bootstrap {
    var proto = Ldtx_YoutubeOutput_V1_Bootstrap()
    proto.protocolVersion = protocolVersion
    proto.context = context.makeProto()
    proto.endpoint = endpoint.absoluteString
    proto.availabilityStartTimeMilliseconds = Int64(
      (availabilityStartTime.timeIntervalSince1970 * 1_000).rounded())
    proto.timescale = Int32(clamping: timescale)
    proto.segmentDurationSeconds = Int32(clamping: segmentDurationSeconds)
    proto.startNumber = Int32(clamping: startNumber)
    proto.mediaTemplate = mediaTemplate
    proto.representation = representation.makeProto()
    proto.configurationFingerprint = configurationFingerprint
    if let initializationSegment { proto.initializationSegment = initializationSegment }
    proto.persistenceIdentifier = persistenceIdentifier
    if let nextMediaTimeSeconds { proto.nextMediaTimeSeconds = nextMediaTimeSeconds }
    return proto
  }
}

extension YouTubeOutputFinishRequest: YouTubeOutputWireMessage {
  public init(proto: Ldtx_YoutubeOutput_V1_FinishRequest) throws {
    self.init(context: try YouTubeOutputContext(proto: proto.context))
  }

  public func makeProto() -> Ldtx_YoutubeOutput_V1_FinishRequest {
    var proto = Ldtx_YoutubeOutput_V1_FinishRequest()
    proto.context = context.makeProto()
    return proto
  }
}

extension YouTubeOutputReply: YouTubeOutputWireMessage {
  public init(proto: Ldtx_YoutubeOutput_V1_Reply) throws {
    self.init(
      context: try YouTubeOutputContext(proto: proto.context),
      sequence: proto.hasSequence ? proto.sequence : nil,
      nextMediaSegmentNumber: proto.hasNextMediaSegmentNumber
        ? Int(proto.nextMediaSegmentNumber) : nil,
      initializationSegment: proto.hasInitializationSegment ? proto.initializationSegment : nil,
      configurationFingerprint: proto.hasConfigurationFingerprint
        ? proto.configurationFingerprint : nil,
      availabilityStartTime: proto.hasAvailabilityStartTimeMilliseconds
        ? Date(
          timeIntervalSince1970: Double(proto.availabilityStartTimeMilliseconds) / 1_000)
        : nil,
      eventDescription: proto.hasEventDescription ? proto.eventDescription : nil,
      errorDescription: proto.hasErrorDescription ? proto.errorDescription : nil
    )
  }

  public func makeProto() -> Ldtx_YoutubeOutput_V1_Reply {
    var proto = Ldtx_YoutubeOutput_V1_Reply()
    proto.context = context.makeProto()
    if let sequence { proto.sequence = sequence }
    if let nextMediaSegmentNumber {
      proto.nextMediaSegmentNumber = Int32(clamping: nextMediaSegmentNumber)
    }
    if let initializationSegment { proto.initializationSegment = initializationSegment }
    if let configurationFingerprint { proto.configurationFingerprint = configurationFingerprint }
    if let availabilityStartTime {
      proto.availabilityStartTimeMilliseconds = Int64(
        (availabilityStartTime.timeIntervalSince1970 * 1_000).rounded())
    }
    if let eventDescription { proto.eventDescription = eventDescription }
    if let errorDescription { proto.errorDescription = errorDescription }
    return proto
  }
}

extension YouTubeOutputResetRequest: YouTubeOutputWireMessage {
  public init(proto: Ldtx_YoutubeOutput_V1_ResetRequest) throws {
    self.init(
      context: try YouTubeOutputContext(proto: proto.context),
      reason: proto.reason,
      nextMediaSegmentNumber: proto.hasNextMediaSegmentNumber
        ? Int(proto.nextMediaSegmentNumber) : nil,
      initializationSegment: proto.hasInitializationSegment ? proto.initializationSegment : nil,
      configurationFingerprint: proto.hasConfigurationFingerprint
        ? proto.configurationFingerprint : nil,
      availabilityStartTime: proto.hasAvailabilityStartTimeMilliseconds
        ? Date(
          timeIntervalSince1970: Double(proto.availabilityStartTimeMilliseconds) / 1_000)
        : nil,
      nextMediaTimeSeconds: proto.hasNextMediaTimeSeconds ? proto.nextMediaTimeSeconds : nil)
  }

  public func makeProto() -> Ldtx_YoutubeOutput_V1_ResetRequest {
    var proto = Ldtx_YoutubeOutput_V1_ResetRequest()
    proto.context = context.makeProto()
    proto.reason = reason
    if let nextMediaSegmentNumber {
      proto.nextMediaSegmentNumber = Int32(clamping: nextMediaSegmentNumber)
    }
    if let initializationSegment { proto.initializationSegment = initializationSegment }
    if let configurationFingerprint { proto.configurationFingerprint = configurationFingerprint }
    if let availabilityStartTime {
      proto.availabilityStartTimeMilliseconds = Int64(
        (availabilityStartTime.timeIntervalSince1970 * 1_000).rounded())
    }
    if let nextMediaTimeSeconds { proto.nextMediaTimeSeconds = nextMediaTimeSeconds }
    return proto
  }
}

extension YouTubeOutputMediaTime: YouTubeOutputWireMessage {
  public init(proto: Ldtx_YoutubeOutput_V1_MediaTime) throws {
    self.init(value: proto.value, timescale: proto.timescale)
  }

  public func makeProto() -> Ldtx_YoutubeOutput_V1_MediaTime {
    var proto = Ldtx_YoutubeOutput_V1_MediaTime()
    proto.value = value
    proto.timescale = timescale
    return proto
  }
}

extension YouTubeOutputH264Format: YouTubeOutputWireMessage {
  public init(proto: Ldtx_YoutubeOutput_V1_H264Format) throws {
    self.init(
      parameterSets: proto.parameterSets,
      nalUnitHeaderLength: proto.nalUnitHeaderLength,
      width: proto.width,
      height: proto.height
    )
  }

  public func makeProto() -> Ldtx_YoutubeOutput_V1_H264Format {
    var proto = Ldtx_YoutubeOutput_V1_H264Format()
    proto.parameterSets = parameterSets
    proto.nalUnitHeaderLength = nalUnitHeaderLength
    proto.width = width
    proto.height = height
    return proto
  }
}

extension YouTubeOutputH264AccessUnit: YouTubeOutputWireMessage {
  public init(proto: Ldtx_YoutubeOutput_V1_H264AccessUnit) throws {
    self.init(
      presentationTime: try YouTubeOutputMediaTime(proto: proto.presentationTime),
      decodeTime: proto.hasDecodeTime ? try YouTubeOutputMediaTime(proto: proto.decodeTime) : nil,
      duration: try YouTubeOutputMediaTime(proto: proto.duration),
      isKeyFrame: proto.keyFrame,
      avccData: proto.avccData
    )
  }

  public func makeProto() -> Ldtx_YoutubeOutput_V1_H264AccessUnit {
    var proto = Ldtx_YoutubeOutput_V1_H264AccessUnit()
    proto.presentationTime = presentationTime.makeProto()
    if let decodeTime { proto.decodeTime = decodeTime.makeProto() }
    proto.duration = duration.makeProto()
    proto.keyFrame = isKeyFrame
    proto.avccData = avccData
    return proto
  }
}

extension YouTubeOutputAACFormat: YouTubeOutputWireMessage {
  public init(proto: Ldtx_YoutubeOutput_V1_AACFormat) throws { self.init(sampleRate: proto.sampleRate, channelCount: proto.channelCount, magicCookie: proto.magicCookie) }
  public func makeProto() -> Ldtx_YoutubeOutput_V1_AACFormat { var proto = Ldtx_YoutubeOutput_V1_AACFormat(); proto.sampleRate = sampleRate; proto.channelCount = channelCount; proto.magicCookie = magicCookie; return proto }
}
extension YouTubeOutputAACAccessUnit: YouTubeOutputWireMessage {
  public init(proto: Ldtx_YoutubeOutput_V1_AACAccessUnit) throws { self.init(presentationTime: try YouTubeOutputMediaTime(proto: proto.presentationTime), duration: try YouTubeOutputMediaTime(proto: proto.duration), sampleCount: proto.sampleCount, sampleSizes: proto.sampleSizes, data: proto.data) }
  public func makeProto() -> Ldtx_YoutubeOutput_V1_AACAccessUnit { var proto = Ldtx_YoutubeOutput_V1_AACAccessUnit(); proto.presentationTime = presentationTime.makeProto(); proto.duration = duration.makeProto(); proto.sampleCount = sampleCount; proto.sampleSizes = sampleSizes; proto.data = data; return proto }
}

extension YouTubeOutputMediaBatch: YouTubeOutputWireMessage {
  public init(proto: Ldtx_YoutubeOutput_V1_MediaBatch) throws {
    self.init(
      context: try YouTubeOutputContext(proto: proto.context),
      sequence: proto.sequence,
      videoFormat: proto.hasVideoFormat
        ? try YouTubeOutputH264Format(proto: proto.videoFormat) : nil,
      video: try proto.video.map(YouTubeOutputH264AccessUnit.init(proto:)),
      audioFormat: proto.hasAudioFormat ? try YouTubeOutputAACFormat(proto: proto.audioFormat) : nil,
      audio: try proto.audio.map(YouTubeOutputAACAccessUnit.init(proto:))
    )
    protocolVersion = proto.protocolVersion
  }

  public func makeProto() -> Ldtx_YoutubeOutput_V1_MediaBatch {
    var proto = Ldtx_YoutubeOutput_V1_MediaBatch()
    proto.protocolVersion = protocolVersion
    proto.context = context.makeProto()
    proto.sequence = sequence
    if let videoFormat { proto.videoFormat = videoFormat.makeProto() }
    if let audioFormat { proto.audioFormat = audioFormat.makeProto() }
    proto.video = video.map { $0.makeProto() }
    proto.audio = audio.map { $0.makeProto() }
    return proto
  }
}
