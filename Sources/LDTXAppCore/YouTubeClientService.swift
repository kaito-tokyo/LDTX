// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import LDTXYouTube
import LDTXYouTubeAuth
import LDTXYouTubeRTMPS

@MainActor
public struct YouTubeClientService {
  typealias LoadedOAuthClient = YouTubeAuthorizationService.LoadedOAuthClient
  typealias AuthorizationResult = YouTubeAuthorizationService.AuthorizationResult
  typealias AuthorizationRestoreResult = YouTubeAuthorizationService.AuthorizationRestoreResult

  struct DASHStreamRequest: Sendable {
    var title: String
    var description: String
    var resolution: YouTubeLiveStreamResolution
    var frameRate: YouTubeLiveStreamFrameRate
    var usesTemporaryStream: Bool
    var existingBroadcast: YouTubeLiveBroadcast?
  }

  struct DASHStreamResult: Sendable {
    var stream: YouTubeLiveStream
    var broadcast: YouTubeLiveBroadcast
    var broadcastID: String
    var dashEndpoint: DASHIngestEndpoint?
    var reusedBoundStream: Bool
    var previousBoundStreamID: String?
  }

  struct DualRTMPSRequest: Sendable {
    var landscapeLiveStreamID: String
    var portraitLiveStreamID: String
  }

  struct LiveStreamChoice: Equatable, Sendable {
    var id: String
    var title: String
    var statusLabel: String?
  }

  private let authorizationService: YouTubeAuthorizationService?

  public init(authorizationService: YouTubeAuthorizationService? = YouTubeAuthorizationService()) {
    self.authorizationService = authorizationService
  }

  static var preview: YouTubeClientService {
    YouTubeClientService(authorizationService: nil)
  }

  func loadOAuthClient(data: Data) throws -> LoadedOAuthClient {
    guard let authorizationService else {
      throw YouTubeClientServiceError.unavailableInPreview
    }
    return try authorizationService.loadOAuthClient(data: data)
  }

  func restorePersistedOAuthClient() throws -> LoadedOAuthClient? {
    guard let authorizationService else {
      throw YouTubeClientServiceError.unavailableInPreview
    }
    return try authorizationService.restorePersistedOAuthClient()
  }

  func authorize(configuration: GoogleOAuthClientConfiguration) async throws -> AuthorizationResult
  {
    guard let authorizationService else {
      throw YouTubeClientServiceError.unavailableInPreview
    }
    return try await withCheckedThrowingContinuation { continuation in
      authorizationService.authorize(configuration: configuration) {
        continuation.resume(with: $0)
      }
    }
  }

  func cancelAuthorization() {
    authorizationService?.cancelAuthorization()
  }

  func restoreStoredAuthorization(
    configuration: GoogleOAuthClientConfiguration
  ) async throws -> AuthorizationRestoreResult {
    guard let authorizationService else {
      throw YouTubeClientServiceError.unavailableInPreview
    }
    return try await withCheckedThrowingContinuation { continuation in
      authorizationService.restoreStoredAuthorization(configuration: configuration) {
        continuation.resume(with: $0)
      }
    }
  }

  func validAccessToken(
    configuration: GoogleOAuthClientConfiguration
  ) async throws -> String {
    guard let authorizationService else {
      throw YouTubeClientServiceError.unavailableInPreview
    }
    return try await withCheckedThrowingContinuation { continuation in
      authorizationService.validAccessToken(configuration: configuration) {
        continuation.resume(with: $0)
      }
    }
  }

  func createDASHStream(accessToken: String, request: DASHStreamRequest) async throws
    -> DASHStreamResult
  {
    let client = YouTubeLiveAPIClient(accessToken: accessToken)
    guard let broadcast = request.existingBroadcast,
      let broadcastID = broadcast.id
    else {
      throw YouTubeClientServiceError.missingExistingBroadcastSelection
    }

    if shouldReuseBoundStream(for: broadcast) {
      guard let boundStreamID = broadcast.contentDetails?.boundStreamId,
        !boundStreamID.isEmpty
      else {
        throw YouTubeClientServiceError.missingBoundLiveStreamID
      }
      guard let stream = try await client.awaitLiveStream(id: boundStreamID) else {
        throw YouTubeClientServiceError.boundLiveStreamNotFound(boundStreamID)
      }
      guard stream.cdn?.ingestionType == "dash" else {
        throw YouTubeClientServiceError.boundLiveStreamIsNotDASH(boundStreamID)
      }
      return DASHStreamResult(
        stream: stream,
        broadcast: broadcast,
        broadcastID: broadcastID,
        dashEndpoint: stream.cdn?.ingestionInfo?.dashEndpoint,
        reusedBoundStream: true,
        previousBoundStreamID: nil
      )
    }

    let stream = try await client.awaitCreateDASHLiveStream(
      title: request.title,
      description: request.description.isEmpty ? nil : request.description,
      resolution: request.resolution,
      frameRate: request.frameRate,
      isReusable: !request.usesTemporaryStream
    )
    guard let streamID = stream.id else {
      throw YouTubeClientServiceError.missingLiveStreamID
    }
    _ = try await client.awaitUnbindLiveBroadcast(broadcastID: broadcastID)

    let boundBroadcast = try await client.awaitBindLiveBroadcast(
      broadcastID: broadcastID,
      streamID: streamID
    )
    return DASHStreamResult(
      stream: stream,
      broadcast: boundBroadcast,
      broadcastID: broadcastID,
      dashEndpoint: stream.cdn?.ingestionInfo?.dashEndpoint,
      reusedBoundStream: false,
      previousBoundStreamID: broadcast.contentDetails?.boundStreamId
    )
  }

  func rollbackDASHStreamCreation(accessToken: String, result: DASHStreamResult) async throws {
    guard !result.reusedBoundStream,
      let streamID = result.stream.id
    else {
      return
    }

    let client = YouTubeLiveAPIClient(accessToken: accessToken)
    _ = try await client.awaitUnbindLiveBroadcast(broadcastID: result.broadcastID)
    if let previousBoundStreamID = result.previousBoundStreamID,
      !previousBoundStreamID.isEmpty
    {
      _ = try await client.awaitBindLiveBroadcast(
        broadcastID: result.broadcastID,
        streamID: previousBoundStreamID
      )
    }
    try await client.awaitDeleteLiveStream(id: streamID)
  }

  func refreshExistingBroadcasts(accessToken: String) async throws -> [YouTubeLiveBroadcast] {
    let client = YouTubeLiveAPIClient(accessToken: accessToken)
    let activeBroadcasts = try await client.awaitListLiveBroadcasts(broadcastStatus: .active)
    let upcomingBroadcasts = try await client.awaitListLiveBroadcasts(broadcastStatus: .upcoming)
    return Self.uniqueBroadcastsByID(activeBroadcasts + upcomingBroadcasts)
  }

  func refreshExistingLiveStreams(accessToken: String) async throws -> [LiveStreamChoice] {
    let client = YouTubeLiveAPIClient(accessToken: accessToken)
    var choices: [LiveStreamChoice] = []
    var pageToken: String?
    var seenPageTokens = Set<String>()
    repeat {
      let page = try await client.awaitLiveStreamPickerPage(mine: true, pageToken: pageToken)
      choices.append(
        contentsOf: page.items.compactMap { stream in
          guard stream.supportsRTMPS, let id = stream.id, !id.isEmpty else { return nil }
          let status = stream.status?.streamStatus
          return LiveStreamChoice(
            id: id,
            title: stream.snippet?.title ?? "Untitled",
            statusLabel: status?.isEmpty == false ? status?.capitalized : nil)
        })
      pageToken = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
      if let pageToken, !seenPageTokens.insert(pageToken).inserted {
        throw YouTubeClientServiceError.repeatedLiveStreamPageToken
      }
    } while pageToken != nil
    return choices
  }

  func dualRTMPSDestinations(accessToken: String, request: DualRTMPSRequest) async throws
    -> YouTubeDualRTMPSDestinations
  {
    let client = YouTubeLiveAPIClient(accessToken: accessToken)
    return try await client.awaitDualRTMPSDestinations(
      landscapeLiveStreamID: request.landscapeLiveStreamID,
      portraitLiveStreamID: request.portraitLiveStreamID)
  }

  func liveStreamStatus(accessToken: String, id: String) async throws
    -> YouTubeLiveStream.Status?
  {
    let client = YouTubeLiveAPIClient(accessToken: accessToken)
    return try await client.awaitLiveStream(id: id)?.status
  }

  func authenticatedChannelID(accessToken: String) async throws -> String? {
    let client = YouTubeLiveAPIClient(accessToken: accessToken)
    return try await client.awaitListChannels(mine: true)
      .compactMap(\.id)
      .first { !$0.isEmpty }
  }

  private static func uniqueBroadcastsByID(_ broadcasts: [YouTubeLiveBroadcast])
    -> [YouTubeLiveBroadcast]
  {
    var seenIDs = Set<String>()
    return broadcasts.filter { broadcast in
      guard let id = broadcast.id else {
        return true
      }
      return seenIDs.insert(id).inserted
    }
  }

  private func shouldReuseBoundStream(for broadcast: YouTubeLiveBroadcast) -> Bool {
    guard broadcast.snippet?.actualEndTime == nil else {
      return false
    }
    let isActive =
      broadcast.status?.lifeCycleStatus == "live"
      || broadcast.status?.lifeCycleStatus == "liveStarting"
      || broadcast.snippet?.actualStartTime != nil
    return isActive
  }
}

extension YouTubeLiveAPIClient {
  fileprivate func awaitLiveStreamPickerPage(
    mine: Bool,
    pageToken: String?
  ) async throws -> YouTubeLiveStreamPickerPage {
    try await withCheckedThrowingContinuation { continuation in
      listLiveStreamPickerPage(mine: mine, pageToken: pageToken) {
        continuation.resume(with: $0)
      }
    }
  }

  fileprivate func awaitDualRTMPSDestinations(
    landscapeLiveStreamID: String,
    portraitLiveStreamID: String
  ) async throws -> YouTubeDualRTMPSDestinations {
    try await withCheckedThrowingContinuation { continuation in
      dualRTMPSDestinations(
        landscapeLiveStreamID: landscapeLiveStreamID,
        portraitLiveStreamID: portraitLiveStreamID
      ) { continuation.resume(with: $0) }
    }
  }

  fileprivate func awaitLiveStream(id: String) async throws -> YouTubeLiveStream? {
    try await withCheckedThrowingContinuation { continuation in
      liveStream(id: id) { continuation.resume(with: $0) }
    }
  }

  fileprivate func awaitCreateDASHLiveStream(
    title: String,
    description: String?,
    resolution: YouTubeLiveStreamResolution,
    frameRate: YouTubeLiveStreamFrameRate,
    isReusable: Bool
  ) async throws -> YouTubeLiveStream {
    try await withCheckedThrowingContinuation { continuation in
      createDASHLiveStream(
        title: title,
        description: description,
        resolution: resolution,
        frameRate: frameRate,
        isReusable: isReusable
      ) { continuation.resume(with: $0) }
    }
  }

  fileprivate func awaitBindLiveBroadcast(
    broadcastID: String,
    streamID: String
  ) async throws -> YouTubeLiveBroadcast {
    try await withCheckedThrowingContinuation { continuation in
      bindLiveBroadcast(broadcastID: broadcastID, streamID: streamID) {
        continuation.resume(with: $0)
      }
    }
  }

  fileprivate func awaitUnbindLiveBroadcast(broadcastID: String) async throws
    -> YouTubeLiveBroadcast
  {
    try await withCheckedThrowingContinuation { continuation in
      unbindLiveBroadcast(broadcastID: broadcastID) { continuation.resume(with: $0) }
    }
  }

  fileprivate func awaitDeleteLiveStream(id: String) async throws {
    try await withCheckedThrowingContinuation { continuation in
      deleteLiveStream(id: id) { continuation.resume(with: $0) }
    }
  }

  fileprivate func awaitListLiveBroadcasts(
    broadcastStatus: YouTubeLiveBroadcastListStatus
  ) async throws -> [YouTubeLiveBroadcast] {
    try await withCheckedThrowingContinuation { continuation in
      listLiveBroadcasts(broadcastStatus: broadcastStatus) { continuation.resume(with: $0) }
    }
  }

  fileprivate func awaitListChannels(mine: Bool) async throws -> [YouTubeChannel] {
    try await withCheckedThrowingContinuation { continuation in
      listChannels(mine: mine) { continuation.resume(with: $0) }
    }
  }
}

enum YouTubeClientServiceError: Error, LocalizedError {
  case unavailableInPreview
  case missingOAuthConfiguration
  case missingExistingBroadcastSelection
  case missingLiveStreamID
  case missingBoundLiveStreamID
  case boundLiveStreamNotFound(String)
  case boundLiveStreamIsNotDASH(String)
  case missingDualRTMPSLiveStreamSelection
  case missingDASHDestination
  case youtubeRTMPSServiceAlreadyInstalled
  case repeatedLiveStreamPageToken

  var errorDescription: String? {
    switch self {
    case .unavailableInPreview:
      "YouTube services are unavailable in SwiftUI previews."
    case .missingOAuthConfiguration:
      "Load an OAuth client before using YouTube."
    case .missingExistingBroadcastSelection:
      "Select an existing YouTube broadcast before preparing the stream."
    case .missingLiveStreamID:
      "The YouTube API response did not include a live stream ID."
    case .missingBoundLiveStreamID:
      "The active YouTube broadcast did not include a bound live stream ID."
    case .boundLiveStreamNotFound(let streamID):
      "The active YouTube broadcast references live stream \(streamID), but the stream could not be loaded."
    case .boundLiveStreamIsNotDASH(let streamID):
      "The active YouTube broadcast references live stream \(streamID), but that stream is not configured for DASH ingest."
    case .missingDualRTMPSLiveStreamSelection:
      "Select different Landscape and Portrait YouTube LiveStreams before starting output."
    case .missingDASHDestination:
      "The selected YouTube LiveStream has no DASH destination."
    case .youtubeRTMPSServiceAlreadyInstalled:
      "A YouTube RTMPS output service is already active."
    case .repeatedLiveStreamPageToken:
      "The YouTube Live Streaming API repeated a LiveStream page token."
    }
  }
}
