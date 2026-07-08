// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import LDTXYouTube
import LDTXYouTubeAuth

@MainActor
struct YouTubeClientService {
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
    }

    private let authorizationService: YouTubeAuthorizationService?

    init(authorizationService: YouTubeAuthorizationService? = YouTubeAuthorizationService()) {
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

    func authorize(configuration: GoogleOAuthClientConfiguration) async throws -> AuthorizationResult {
        guard let authorizationService else {
            throw YouTubeClientServiceError.unavailableInPreview
        }
        return try await authorizationService.authorize(configuration: configuration)
    }

    func restoreStoredAuthorization(
        configuration: GoogleOAuthClientConfiguration
    ) async throws -> AuthorizationRestoreResult {
        guard let authorizationService else {
            throw YouTubeClientServiceError.unavailableInPreview
        }
        return try await authorizationService.restoreStoredAuthorization(configuration: configuration)
    }

    func validAccessToken(
        configuration: GoogleOAuthClientConfiguration
    ) async throws -> String {
        guard let authorizationService else {
            throw YouTubeClientServiceError.unavailableInPreview
        }
        return try await authorizationService.validAccessToken(configuration: configuration)
    }

    func createDASHStream(accessToken: String, request: DASHStreamRequest) async throws -> DASHStreamResult {
        let client = YouTubeLiveAPIClient(accessToken: accessToken)
        guard let broadcast = request.existingBroadcast,
              let broadcastID = broadcast.id else {
            throw YouTubeClientServiceError.missingExistingBroadcastSelection
        }

        if shouldReuseBoundStream(for: broadcast) {
            guard let boundStreamID = broadcast.contentDetails?.boundStreamId,
                  !boundStreamID.isEmpty else {
                throw YouTubeClientServiceError.missingBoundLiveStreamID
            }
            guard let stream = try await client.liveStream(id: boundStreamID) else {
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
                reusedBoundStream: true
            )
        }

        let stream = try await client.createDASHLiveStream(
            title: request.title,
            description: request.description.isEmpty ? nil : request.description,
            resolution: request.resolution,
            frameRate: request.frameRate,
            isReusable: !request.usesTemporaryStream
        )
        guard let streamID = stream.id else {
            throw YouTubeClientServiceError.missingLiveStreamID
        }
        _ = try await client.unbindLiveBroadcast(broadcastID: broadcastID)

        let boundBroadcast = try await client.bindLiveBroadcast(
            broadcastID: broadcastID,
            streamID: streamID
        )
        return DASHStreamResult(
            stream: stream,
            broadcast: boundBroadcast,
            broadcastID: broadcastID,
            dashEndpoint: stream.cdn?.ingestionInfo?.dashEndpoint,
            reusedBoundStream: false
        )
    }

    func refreshExistingBroadcasts(accessToken: String) async throws -> [YouTubeLiveBroadcast] {
        let client = YouTubeLiveAPIClient(accessToken: accessToken)
        let activeBroadcasts = try await client.listLiveBroadcasts(broadcastStatus: .active)
        let upcomingBroadcasts = try await client.listLiveBroadcasts(broadcastStatus: .upcoming)
        return Self.uniqueBroadcastsByID(activeBroadcasts + upcomingBroadcasts)
    }

    func authenticatedChannelID(accessToken: String) async throws -> String? {
        let client = YouTubeLiveAPIClient(accessToken: accessToken)
        return try await client.listChannels(mine: true)
            .compactMap(\.id)
            .first { !$0.isEmpty }
    }

    private static func uniqueBroadcastsByID(_ broadcasts: [YouTubeLiveBroadcast]) -> [YouTubeLiveBroadcast] {
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
            broadcast.status?.lifeCycleStatus == "live" ||
            broadcast.status?.lifeCycleStatus == "liveStarting" ||
            broadcast.snippet?.actualStartTime != nil
        return isActive
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
        case let .boundLiveStreamNotFound(streamID):
            "The active YouTube broadcast references live stream \(streamID), but the stream could not be loaded."
        case let .boundLiveStreamIsNotDASH(streamID):
            "The active YouTube broadcast references live stream \(streamID), but that stream is not configured for DASH ingest."
        }
    }
}
