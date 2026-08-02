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
    completionHandler:
      @escaping @MainActor @Sendable (Result<AuthorizationResult, any Error>) -> Void
  ) {
    authorizationPresenter.authorize(
      requestBuilder: { redirectURI in
        try makeAuthorizationRequest(
          configuration: configuration,
          scopes: [YouTubeLiveScope.manageLiveStreaming],
          redirectURI: redirectURI,
          additionalParameters: ["access_type": "offline", "prompt": "consent"]
        )
      },
      completionHandler: { result in
        switch result {
        case .failure(let error):
          completionHandler(.failure(error))
        case .success(let authState):
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
    )
  }

  public func cancelAuthorization() {
    authorizationPresenter.cancelAuthorization()
  }

  public func restoreStoredAuthorization(
    configuration: GoogleOAuthClientConfiguration,
    completionHandler:
      @escaping @MainActor @Sendable (Result<AuthorizationRestoreResult, any Error>) -> Void
  ) {
    let authState: OIDAuthState
    do {
      guard let storedAuthState = try authorizationStore.load(clientID: configuration.clientID)
      else {
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
      guard let storedAuthState = try authorizationStore.load(clientID: configuration.clientID)
      else {
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
    redirectURI: URL,
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
      redirectURL: redirectURI,
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
            completionHandler(
              .failure(
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

  public var errorDescription: String? {
    switch self {
    case .missingAuthorization:
      "Authorize YouTube before creating a stream."
    }
  }
}
