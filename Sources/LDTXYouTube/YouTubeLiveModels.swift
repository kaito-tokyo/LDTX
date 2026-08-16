// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import LDTXYouTubeRTMPS

public enum YouTubeLiveScope {
  public static let manageLiveStreaming = "https://www.googleapis.com/auth/youtube"
}

public enum YouTubeLiveStreamResolution: String, Codable, CaseIterable, Sendable {
  case p240 = "240p"
  case p360 = "360p"
  case p480 = "480p"
  case p720 = "720p"
  case p1080 = "1080p"
  case p1440 = "1440p"
  case p2160 = "2160p"
}

public enum YouTubeLiveStreamFrameRate: String, Codable, CaseIterable, Sendable {
  case fps30 = "30fps"
  case fps60 = "60fps"
}

public enum YouTubeLiveBroadcastPrivacyStatus: String, Codable, CaseIterable, Sendable {
  case `private`
  case unlisted
  case `public`
}

public enum YouTubeLiveBroadcastLatencyPreference: String, Codable, CaseIterable, Sendable {
  case normal
  case low
  case ultraLow
}

public enum YouTubeLiveBroadcastListStatus: String, Codable, CaseIterable, Sendable {
  case active
  case all
  case completed
  case upcoming
}

public struct YouTubeChannel: Codable, Equatable, Sendable, Identifiable {
  public var kind: String?
  public var etag: String?
  public var id: String?
  public var snippet: Snippet?

  public init(
    kind: String? = nil,
    etag: String? = nil,
    id: String? = nil,
    snippet: Snippet? = nil
  ) {
    self.kind = kind
    self.etag = etag
    self.id = id
    self.snippet = snippet
  }

  public struct Snippet: Codable, Equatable, Sendable {
    public var title: String?
    public var description: String?
    public var customUrl: String?

    public init(
      title: String? = nil,
      description: String? = nil,
      customUrl: String? = nil
    ) {
      self.title = title
      self.description = description
      self.customUrl = customUrl
    }
  }
}

public struct YouTubeLiveBroadcast: Codable, Equatable, Sendable, Identifiable {
  public var kind: String?
  public var etag: String?
  public var id: String?
  public var snippet: Snippet?
  public var status: Status?
  public var contentDetails: ContentDetails?

  public init(
    kind: String? = nil,
    etag: String? = nil,
    id: String? = nil,
    snippet: Snippet? = nil,
    status: Status? = nil,
    contentDetails: ContentDetails? = nil
  ) {
    self.kind = kind
    self.etag = etag
    self.id = id
    self.snippet = snippet
    self.status = status
    self.contentDetails = contentDetails
  }

  public struct Snippet: Codable, Equatable, Sendable {
    public var publishedAt: String?
    public var channelId: String?
    public var title: String
    public var description: String?
    public var scheduledStartTime: String?
    public var scheduledEndTime: String?
    public var actualStartTime: String?
    public var actualEndTime: String?

    public init(
      publishedAt: String? = nil,
      channelId: String? = nil,
      title: String,
      description: String? = nil,
      scheduledStartTime: String? = nil,
      scheduledEndTime: String? = nil,
      actualStartTime: String? = nil,
      actualEndTime: String? = nil
    ) {
      self.publishedAt = publishedAt
      self.channelId = channelId
      self.title = title
      self.description = description
      self.scheduledStartTime = scheduledStartTime
      self.scheduledEndTime = scheduledEndTime
      self.actualStartTime = actualStartTime
      self.actualEndTime = actualEndTime
    }
  }

  public struct Status: Codable, Equatable, Sendable {
    public var lifeCycleStatus: String?
    public var privacyStatus: YouTubeLiveBroadcastPrivacyStatus?
    public var recordingStatus: String?
    public var madeForKids: Bool?
    public var selfDeclaredMadeForKids: Bool?

    public init(
      lifeCycleStatus: String? = nil,
      privacyStatus: YouTubeLiveBroadcastPrivacyStatus? = nil,
      recordingStatus: String? = nil,
      madeForKids: Bool? = nil,
      selfDeclaredMadeForKids: Bool? = nil
    ) {
      self.lifeCycleStatus = lifeCycleStatus
      self.privacyStatus = privacyStatus
      self.recordingStatus = recordingStatus
      self.madeForKids = madeForKids
      self.selfDeclaredMadeForKids = selfDeclaredMadeForKids
    }
  }

  public struct ContentDetails: Codable, Equatable, Sendable {
    public var boundStreamId: String?
    public var enableAutoStart: Bool?
    public var enableAutoStop: Bool?
    public var enableDvr: Bool?
    public var recordFromStart: Bool?
    public var latencyPreference: YouTubeLiveBroadcastLatencyPreference?

    public init(
      boundStreamId: String? = nil,
      enableAutoStart: Bool? = nil,
      enableAutoStop: Bool? = nil,
      enableDvr: Bool? = nil,
      recordFromStart: Bool? = nil,
      latencyPreference: YouTubeLiveBroadcastLatencyPreference? = nil
    ) {
      self.boundStreamId = boundStreamId
      self.enableAutoStart = enableAutoStart
      self.enableAutoStop = enableAutoStop
      self.enableDvr = enableDvr
      self.recordFromStart = recordFromStart
      self.latencyPreference = latencyPreference
    }
  }
}

public struct YouTubeLiveStream: Codable, Equatable, Sendable, Identifiable {
  public var kind: String?
  public var etag: String?
  public var id: String?
  public var snippet: Snippet?
  public var cdn: CDN?
  public var status: Status?
  public var contentDetails: ContentDetails?

  public init(
    kind: String? = nil,
    etag: String? = nil,
    id: String? = nil,
    snippet: Snippet? = nil,
    cdn: CDN? = nil,
    status: Status? = nil,
    contentDetails: ContentDetails? = nil
  ) {
    self.kind = kind
    self.etag = etag
    self.id = id
    self.snippet = snippet
    self.cdn = cdn
    self.status = status
    self.contentDetails = contentDetails
  }

  public struct Snippet: Codable, Equatable, Sendable {
    public var publishedAt: String?
    public var channelId: String?
    public var title: String
    public var description: String?

    public init(
      publishedAt: String? = nil, channelId: String? = nil, title: String,
      description: String? = nil
    ) {
      self.publishedAt = publishedAt
      self.channelId = channelId
      self.title = title
      self.description = description
    }
  }

  public struct CDN: Codable, Equatable, Sendable {
    public var ingestionType: String
    public var ingestionInfo: IngestionInfo?
    public var resolution: String
    public var frameRate: String

    public init(
      ingestionType: String, ingestionInfo: IngestionInfo? = nil, resolution: String,
      frameRate: String
    ) {
      self.ingestionType = ingestionType
      self.ingestionInfo = ingestionInfo
      self.resolution = resolution
      self.frameRate = frameRate
    }
  }

  public struct IngestionInfo: Codable, Equatable, Sendable {
    public var streamName: String?
    public var ingestionAddress: String?
    public var backupIngestionAddress: String?
    public var rtmpsIngestionAddress: String?
    public var rtmpsBackupIngestionAddress: String?

    public init(
      streamName: String? = nil, ingestionAddress: String? = nil,
      backupIngestionAddress: String? = nil,
      rtmpsIngestionAddress: String? = nil,
      rtmpsBackupIngestionAddress: String? = nil
    ) {
      self.streamName = streamName
      self.ingestionAddress = ingestionAddress
      self.backupIngestionAddress = backupIngestionAddress
      self.rtmpsIngestionAddress = rtmpsIngestionAddress
      self.rtmpsBackupIngestionAddress = rtmpsBackupIngestionAddress
    }

    public var dashEndpoint: DASHIngestEndpoint? {
      guard let ingestionAddress, let url = URL(string: ingestionAddress) else {
        return nil
      }
      return DASHIngestEndpoint(baseURL: url)
    }

    public var rtmpsURL: URL? {
      guard let rtmpsIngestionAddress else { return nil }
      return URL(string: rtmpsIngestionAddress)
    }

    public var rtmpsDestination: YouTubeRTMPSDestination? {
      guard let rtmpsURL, let streamName else { return nil }
      return try? YouTubeRTMPSDestination(ingestionURL: rtmpsURL, streamName: streamName)
    }
  }

  public struct Status: Codable, Equatable, Sendable {
    public var streamStatus: String?
    public var healthStatus: HealthStatus?

    public init(streamStatus: String? = nil, healthStatus: HealthStatus? = nil) {
      self.streamStatus = streamStatus
      self.healthStatus = healthStatus
    }
  }

  public struct HealthStatus: Codable, Equatable, Sendable {
    public var status: String?
    public var lastUpdateTimeSeconds: String?

    public init(status: String? = nil, lastUpdateTimeSeconds: String? = nil) {
      self.status = status
      self.lastUpdateTimeSeconds = lastUpdateTimeSeconds
    }
  }

  public struct ContentDetails: Codable, Equatable, Sendable {
    public var closedCaptionsIngestionUrl: String?
    public var isReusable: Bool?

    public init(closedCaptionsIngestionUrl: String? = nil, isReusable: Bool? = nil) {
      self.closedCaptionsIngestionUrl = closedCaptionsIngestionUrl
      self.isReusable = isReusable
    }
  }
}

public struct YouTubeLiveStreamListResponse: Decodable, Equatable, Sendable {
  public var items: [YouTubeLiveStream]
}

public struct YouTubeLiveBroadcastListResponse: Decodable, Equatable, Sendable {
  public var items: [YouTubeLiveBroadcast]
}

public struct YouTubeChannelListResponse: Decodable, Equatable, Sendable {
  public var items: [YouTubeChannel]
}
