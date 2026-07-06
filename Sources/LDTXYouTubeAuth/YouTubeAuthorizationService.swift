// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AppAuth
import Foundation
import LDTXYouTube

@MainActor
public struct YouTubeAuthorizationService {
    public struct LoadedOAuthClient: Sendable {
        public var configuration: GoogleOAuthClientConfiguration
    }

    public struct AuthorizationResult: Sendable {
        public var accessToken: String
    }

    public enum AuthorizationRestoreResult: Sendable {
        case notAuthorized
        case authorized(accessToken: String)
    }

    private let authorizationStore: YouTubeAuthorizationStore
    private let oauthClientStore: OAuthClientConfigurationStore
    private let authorizationPresenter = AppAuthAuthorizationPresenter()

    public init(
        authorizationStore: YouTubeAuthorizationStore = YouTubeAuthorizationStore(),
        oauthClientStore: OAuthClientConfigurationStore = OAuthClientConfigurationStore()
    ) {
        self.authorizationStore = authorizationStore
        self.oauthClientStore = oauthClientStore
    }

    public func loadOAuthClient(data: Data) throws -> LoadedOAuthClient {
        let configuration = try GoogleOAuthClientConfiguration(data: data)
        try oauthClientStore.save(data)
        return LoadedOAuthClient(configuration: configuration)
    }

    public func restorePersistedOAuthClient() throws -> LoadedOAuthClient? {
        guard let configuration = try oauthClientStore.load() else {
            return nil
        }
        return LoadedOAuthClient(configuration: configuration)
    }

    public func authorize(configuration: GoogleOAuthClientConfiguration) async throws -> AuthorizationResult {
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

    public func restoreStoredAuthorization(
        configuration: GoogleOAuthClientConfiguration
    ) async throws -> AuthorizationRestoreResult {
        guard let authState = try authorizationStore.load(clientID: configuration.clientID) else {
            return .notAuthorized
        }

        let accessToken = try await freshAccessToken(for: authState, configuration: configuration)
        return .authorized(accessToken: accessToken)
    }

    public func validAccessToken(
        configuration: GoogleOAuthClientConfiguration
    ) async throws -> String {
        guard let authState = try authorizationStore.load(clientID: configuration.clientID) else {
            throw YouTubeAuthorizationServiceError.missingAuthorization
        }
        return try await freshAccessToken(for: authState, configuration: configuration)
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
                    continuation.resume(throwing: error ?? YouTubeAuthorizationServiceError.missingAuthorization)
                }
            }
        }
        try authorizationStore.save(authState, clientID: configuration.clientID)
        return accessToken
    }
}

public enum YouTubeAuthorizationServiceError: Error, LocalizedError {
    case missingAuthorization
    case missingOAuthRedirectURI(URL)

    public var errorDescription: String? {
        switch self {
        case .missingAuthorization:
            "Authorize YouTube before creating a stream."
        case let .missingOAuthRedirectURI(redirectURI):
            "The OAuth client JSON must include the redirect URI \(redirectURI.absoluteString)."
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
            throw YouTubeAuthorizationServiceError.missingOAuthRedirectURI(YouTubeOAuthRedirect.defaultRedirectURI)
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
