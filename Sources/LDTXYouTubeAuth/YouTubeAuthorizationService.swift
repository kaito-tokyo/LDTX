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

    public func authorize(
        configuration: GoogleOAuthClientConfiguration,
        completionHandler: @escaping @MainActor @Sendable (Result<AuthorizationResult, any Error>) -> Void
    ) {
        let request: OIDAuthorizationRequest
        do {
            request = try makeAuthorizationRequest(
                configuration: configuration,
                scopes: [YouTubeLiveScope.manageLiveStreaming],
                additionalParameters: ["access_type": "offline", "prompt": "consent"]
            )
        } catch {
            completionHandler(.failure(error))
            return
        }
        authorizationPresenter.authorize(request: request) { result in
            switch result {
            case let .failure(error):
                completionHandler(.failure(error))
            case let .success(authState):
                do {
                    try authorizationStore.save(authState, clientID: configuration.clientID)
                } catch {
                    completionHandler(.failure(error))
                    return
                }
                freshAccessToken(for: authState, configuration: configuration) { result in
                    completionHandler(result.map { AuthorizationResult(accessToken: $0) })
                }
            }
        }
    }

    public func restoreStoredAuthorization(
        configuration: GoogleOAuthClientConfiguration,
        completionHandler: @escaping @MainActor @Sendable (Result<AuthorizationRestoreResult, any Error>) -> Void
    ) {
        let authState: OIDAuthState
        do {
            guard let storedAuthState = try authorizationStore.load(clientID: configuration.clientID) else {
                completionHandler(.success(.notAuthorized))
                return
            }
            authState = storedAuthState
        } catch {
            completionHandler(.failure(error))
            return
        }
        freshAccessToken(for: authState, configuration: configuration) { result in
            completionHandler(result.map { .authorized(accessToken: $0) })
        }
    }

    public func validAccessToken(
        configuration: GoogleOAuthClientConfiguration,
        completionHandler: @escaping @MainActor @Sendable (Result<String, any Error>) -> Void
    ) {
        let authState: OIDAuthState
        do {
            guard let storedAuthState = try authorizationStore.load(clientID: configuration.clientID) else {
                completionHandler(.failure(YouTubeAuthorizationServiceError.missingAuthorization))
                return
            }
            authState = storedAuthState
        } catch {
            completionHandler(.failure(error))
            return
        }
        freshAccessToken(
            for: authState,
            configuration: configuration,
            completionHandler: completionHandler
        )
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
        configuration: GoogleOAuthClientConfiguration,
        completionHandler: @escaping @MainActor @Sendable (Result<String, any Error>) -> Void
    ) {
        authState.performAction { accessToken, _, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let accessToken else {
                        completionHandler(.failure(
                            error ?? YouTubeAuthorizationServiceError.missingAuthorization
                        ))
                        return
                    }
                    do {
                        try authorizationStore.save(authState, clientID: configuration.clientID)
                        completionHandler(.success(accessToken))
                    } catch {
                        completionHandler(.failure(error))
                    }
                }
            }
        }
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
