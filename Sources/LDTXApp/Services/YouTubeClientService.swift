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
        var sourceMode: BroadcastSourceMode
        var existingBroadcastID: String?
        var privacyStatus: YouTubeLiveBroadcastPrivacyStatus
        var latencyPreference: YouTubeLiveBroadcastLatencyPreference
    }

    struct DASHStreamResult: Sendable {
        var stream: YouTubeLiveStream
        var broadcast: YouTubeLiveBroadcast
        var broadcastID: String
        var dashEndpoint: DASHIngestEndpoint?
    }

    private let authorizationService: YouTubeAuthorizationService

    init(authorizationService: YouTubeAuthorizationService = YouTubeAuthorizationService()) {
        self.authorizationService = authorizationService
    }

    func loadOAuthClient(data: Data) throws -> LoadedOAuthClient {
        try authorizationService.loadOAuthClient(data: data)
    }

    func restorePersistedOAuthClient() throws -> LoadedOAuthClient? {
        try authorizationService.restorePersistedOAuthClient()
    }

    func authorize(configuration: GoogleOAuthClientConfiguration) async throws -> AuthorizationResult {
        try await authorizationService.authorize(configuration: configuration)
    }

    func restoreStoredAuthorization(
        configuration: GoogleOAuthClientConfiguration
    ) async throws -> AuthorizationRestoreResult {
        try await authorizationService.restoreStoredAuthorization(configuration: configuration)
    }

    func validAccessToken(
        configuration: GoogleOAuthClientConfiguration
    ) async throws -> String {
        try await authorizationService.validAccessToken(configuration: configuration)
    }

    func createDASHStream(accessToken: String, request: DASHStreamRequest) async throws -> DASHStreamResult {
        let client = YouTubeLiveAPIClient(accessToken: accessToken)
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

        let broadcastID: String
        switch request.sourceMode {
        case .createNew:
            let broadcast = try await client.createLiveBroadcast(
                title: request.title,
                description: request.description.isEmpty ? nil : request.description,
                scheduledStartTime: Date().addingTimeInterval(60),
                privacyStatus: request.privacyStatus,
                latencyPreference: request.latencyPreference
            )
            guard let createdBroadcastID = broadcast.id else {
                throw YouTubeClientServiceError.missingLiveBroadcastID
            }
            broadcastID = createdBroadcastID

        case .useExisting:
            guard let existingBroadcastID = request.existingBroadcastID else {
                throw YouTubeClientServiceError.missingExistingBroadcastSelection
            }
            broadcastID = existingBroadcastID
            _ = try await client.unbindLiveBroadcast(broadcastID: existingBroadcastID)
        }

        let boundBroadcast = try await client.bindLiveBroadcast(
            broadcastID: broadcastID,
            streamID: streamID
        )
        return DASHStreamResult(
            stream: stream,
            broadcast: boundBroadcast,
            broadcastID: broadcastID,
            dashEndpoint: stream.cdn?.ingestionInfo?.dashEndpoint
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
}

enum YouTubeClientServiceError: Error, LocalizedError {
    case missingOAuthConfiguration
    case missingExistingBroadcastSelection
    case missingLiveStreamID
    case missingLiveBroadcastID

    var errorDescription: String? {
        switch self {
        case .missingOAuthConfiguration:
            "Load an OAuth client before using YouTube."
        case .missingExistingBroadcastSelection:
            "Select an existing YouTube broadcast before preparing the stream."
        case .missingLiveStreamID:
            "The YouTube API response did not include a live stream ID."
        case .missingLiveBroadcastID:
            "The YouTube API response did not include a live broadcast ID."
        }
    }
}
