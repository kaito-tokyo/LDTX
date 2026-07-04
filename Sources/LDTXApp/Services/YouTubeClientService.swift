// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LDTXDash
import LDTXOAuth
import LDTXYouTube

@MainActor
struct YouTubeClientService {
    struct LoadedOAuthClient: Sendable {
        var configuration: GoogleOAuthClientConfiguration
    }

    struct AuthorizationResult: Sendable {
        var tokenResponse: OAuthTokenResponse
        var storedToken: StoredOAuthToken
    }

    enum AuthorizationRestoreResult: Sendable {
        case notAuthorized
        case restored(StoredOAuthToken)
        case expired
        case refreshed(StoredOAuthToken)
    }

    struct AccessTokenResult: Sendable {
        var accessToken: String
        var tokenResponse: OAuthTokenResponse?
        var storedToken: StoredOAuthToken?
    }

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

    private let tokenStore: any OAuthTokenStoring
    private let oauthClientStore: any OAuthClientConfigurationStoring

    init(
        tokenStore: any OAuthTokenStoring,
        oauthClientStore: any OAuthClientConfigurationStoring
    ) {
        self.tokenStore = tokenStore
        self.oauthClientStore = oauthClientStore
    }

    func loadOAuthClient(data: Data) throws -> LoadedOAuthClient {
        let configuration = try GoogleOAuthClientConfiguration(data: data)
        try oauthClientStore.save(data)
        return LoadedOAuthClient(configuration: configuration)
    }

    func restorePersistedOAuthClient() throws -> LoadedOAuthClient? {
        guard let configuration = try oauthClientStore.load() else {
            return nil
        }
        return LoadedOAuthClient(configuration: configuration)
    }

    func authorize(configuration: GoogleOAuthClientConfiguration) async throws -> AuthorizationResult {
        let receiver = try OAuthLoopbackReceiver()
        defer { receiver.cancel() }

        let verifier = try PKCE.makeVerifier()
        let state = UUID().uuidString
        let request = OAuthAuthorizationRequest(
            configuration: configuration,
            redirectURI: receiver.redirectURI,
            scopes: [YouTubeLiveScope.manageLiveStreaming],
            state: state,
            codeChallenge: PKCE.challenge(for: verifier)
        )

        NSWorkspace.shared.open(request.url)

        let redirect = try await receiver.receive()
        guard redirect.state == state else {
            throw YouTubeClientServiceError.invalidOAuthState
        }

        let tokenClient = OAuthTokenClient()
        let response = try await tokenClient.exchangeAuthorizationCode(
            redirect.code,
            verifier: verifier,
            redirectURI: receiver.redirectURI,
            configuration: configuration
        )
        let storedToken = StoredOAuthToken(response: response)
        try tokenStore.save(storedToken, clientID: configuration.clientID)
        return AuthorizationResult(
            tokenResponse: response,
            storedToken: storedToken
        )
    }

    func restoreStoredAuthorization(
        configuration: GoogleOAuthClientConfiguration
    ) async throws -> AuthorizationRestoreResult {
        guard let storedToken = try tokenStore.load(clientID: configuration.clientID) else {
            return .notAuthorized
        }

        if storedToken.isAccessTokenValid() {
            return .restored(storedToken)
        }

        guard let refreshToken = storedToken.refreshToken else {
            return .expired
        }

        let tokenClient = OAuthTokenClient()
        let refreshed = try await tokenClient.refreshAccessToken(
            refreshToken,
            configuration: configuration
        )
        let updatedToken = storedToken.replacingResponseAfterRefresh(refreshed)
        try tokenStore.save(updatedToken, clientID: configuration.clientID)
        return .refreshed(updatedToken)
    }

    func validAccessToken(
        configuration: GoogleOAuthClientConfiguration,
        tokenResponse: OAuthTokenResponse?,
        storedOAuthToken: StoredOAuthToken?
    ) async throws -> AccessTokenResult {
        if let storedOAuthToken, storedOAuthToken.isAccessTokenValid() {
            return AccessTokenResult(
                accessToken: storedOAuthToken.response.accessToken,
                tokenResponse: nil,
                storedToken: nil
            )
        }

        if let tokenResponse, !tokenResponse.accessToken.isEmpty, tokenResponse.expiresIn == nil {
            return AccessTokenResult(
                accessToken: tokenResponse.accessToken,
                tokenResponse: nil,
                storedToken: nil
            )
        }

        guard let storedToken = try tokenStore.load(clientID: configuration.clientID) else {
            throw YouTubeClientServiceError.missingAuthorization
        }

        if storedToken.isAccessTokenValid() {
            return AccessTokenResult(
                accessToken: storedToken.response.accessToken,
                tokenResponse: storedToken.response,
                storedToken: storedToken
            )
        }

        guard let refreshToken = storedToken.refreshToken else {
            throw YouTubeClientServiceError.missingAuthorization
        }

        let tokenClient = OAuthTokenClient()
        let refreshed = try await tokenClient.refreshAccessToken(
            refreshToken,
            configuration: configuration
        )
        let updatedToken = storedToken.replacingResponseAfterRefresh(refreshed)
        try tokenStore.save(updatedToken, clientID: configuration.clientID)
        return AccessTokenResult(
            accessToken: updatedToken.response.accessToken,
            tokenResponse: updatedToken.response,
            storedToken: updatedToken
        )
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
        return try await client.listLiveBroadcasts(broadcastStatus: .upcoming)
    }

    func authenticatedChannelID(accessToken: String) async throws -> String? {
        let client = YouTubeLiveAPIClient(accessToken: accessToken)
        return try await client.listChannels(mine: true)
            .compactMap(\.id)
            .first { !$0.isEmpty }
    }
}

enum YouTubeClientServiceError: Error, LocalizedError {
    case invalidOAuthState
    case missingOAuthConfiguration
    case missingAuthorization
    case missingExistingBroadcastSelection
    case missingLiveStreamID
    case missingLiveBroadcastID

    var errorDescription: String? {
        switch self {
        case .invalidOAuthState:
            "The OAuth callback state did not match the authorization request."
        case .missingOAuthConfiguration:
            "Load an OAuth client before using YouTube."
        case .missingAuthorization:
            "Authorize YouTube before creating a stream."
        case .missingExistingBroadcastSelection:
            "Select an existing YouTube broadcast before preparing the stream."
        case .missingLiveStreamID:
            "The YouTube API response did not include a live stream ID."
        case .missingLiveBroadcastID:
            "The YouTube API response did not include a live broadcast ID."
        }
    }
}
