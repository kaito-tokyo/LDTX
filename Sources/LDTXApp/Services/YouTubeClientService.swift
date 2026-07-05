// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AppAuth
import Foundation
import LDTXDash
import LDTXYouTube

@MainActor
struct YouTubeClientService {
    struct LoadedOAuthClient: Sendable {
        var configuration: GoogleOAuthClientConfiguration
    }

    struct AuthorizationResult: Sendable {
        var accessToken: String
    }

    enum AuthorizationRestoreResult: Sendable {
        case notAuthorized
        case authorized(accessToken: String)
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

    private let authorizationStore: YouTubeAuthorizationStore
    private let oauthClientStore: OAuthClientConfigurationStore
    private let authorizationPresenter = AppAuthAuthorizationPresenter()

    init(
        authorizationStore: YouTubeAuthorizationStore,
        oauthClientStore: OAuthClientConfigurationStore
    ) {
        self.authorizationStore = authorizationStore
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
        let request = try makeAuthorizationRequest(
            configuration: configuration,
            scopes: [YouTubeLiveScope.manageLiveStreaming],
            additionalParameters: ["access_type": "offline", "prompt": "consent"]
        )
        let authState = try await authorizationPresenter.authorize(request: request)
        try authorizationStore.save(authState, clientID: configuration.clientID)
        let accessToken = try await freshAccessToken(for: authState, configuration: configuration)
        return AuthorizationResult(accessToken: accessToken)
    }

    func restoreStoredAuthorization(
        configuration: GoogleOAuthClientConfiguration
    ) async throws -> AuthorizationRestoreResult {
        guard let authState = try authorizationStore.load(clientID: configuration.clientID) else {
            return .notAuthorized
        }

        let accessToken = try await freshAccessToken(for: authState, configuration: configuration)
        return .authorized(accessToken: accessToken)
    }

    func validAccessToken(
        configuration: GoogleOAuthClientConfiguration
    ) async throws -> String {
        guard let authState = try authorizationStore.load(clientID: configuration.clientID) else {
            throw YouTubeClientServiceError.missingAuthorization
        }
        return try await freshAccessToken(for: authState, configuration: configuration)
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

    private func makeAuthorizationRequest(
        configuration: GoogleOAuthClientConfiguration,
        scopes: [String],
        additionalParameters: [String: String]
    ) throws -> OIDAuthorizationRequest {
        let serviceConfiguration = OIDServiceConfiguration(
            authorizationEndpoint: configuration.authURI,
            tokenEndpoint: configuration.tokenURI
        )
        return OIDAuthorizationRequest(
            configuration: serviceConfiguration,
            clientId: configuration.clientID,
            clientSecret: configuration.clientSecret,
            scopes: scopes,
            redirectURL: try configuration.appAuthRedirectURI(),
            responseType: OIDResponseTypeCode,
            additionalParameters: additionalParameters
        )
    }

    private func freshAccessToken(
        for authState: OIDAuthState,
        configuration: GoogleOAuthClientConfiguration
    ) async throws -> String {
        let accessToken = try await withCheckedThrowingContinuation { continuation in
            authState.performAction { accessToken, _, error in
                if let accessToken {
                    continuation.resume(returning: accessToken)
                } else {
                    continuation.resume(throwing: error ?? YouTubeClientServiceError.missingAuthorization)
                }
            }
        }
        try authorizationStore.save(authState, clientID: configuration.clientID)
        return accessToken
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
    case missingAuthorization
    case missingOAuthRedirectURI(URL)
    case missingExistingBroadcastSelection
    case missingLiveStreamID
    case missingLiveBroadcastID

    var errorDescription: String? {
        switch self {
        case .missingOAuthConfiguration:
            "Load an OAuth client before using YouTube."
        case .missingAuthorization:
            "Authorize YouTube before creating a stream."
        case let .missingOAuthRedirectURI(redirectURI):
            "The OAuth client JSON must include the redirect URI \(redirectURI.absoluteString)."
        case .missingExistingBroadcastSelection:
            "Select an existing YouTube broadcast before preparing the stream."
        case .missingLiveStreamID:
            "The YouTube API response did not include a live stream ID."
        case .missingLiveBroadcastID:
            "The YouTube API response did not include a live broadcast ID."
        }
    }
}

private extension GoogleOAuthClientConfiguration {
    func appAuthRedirectURI() throws -> URL {
        if let redirectURI = redirectURIs.first(where: { redirectURI in
            guard let scheme = redirectURI.scheme else { return false }
            return scheme != "http" && scheme != "https"
        }) {
            return redirectURI
        }

        guard let redirectURI = URL(string: "\(googleAppAuthCallbackURLScheme):/oauth2redirect/google") else {
            throw YouTubeClientServiceError.missingOAuthRedirectURI(YouTubeOAuthRedirect.defaultRedirectURI)
        }
        return redirectURI
    }

    private var googleAppAuthCallbackURLScheme: String {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else {
            return YouTubeOAuthRedirect.callbackURLScheme
        }
        return "com.googleusercontent.apps.\(clientID.dropLast(suffix.count))"
    }
}

private enum YouTubeOAuthRedirect {
    static let callbackURLScheme = "tokyo.kaito.ldtx"
    static let defaultRedirectURI = URL(string: "\(callbackURLScheme):/oauth2redirect/google")!
}
