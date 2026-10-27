// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXYouTube

@MainActor
public struct YouTubeAuthorizationService {
  #if !LDTX_DISTRIBUTION
    private static var applicationFile: YouTubeAuthFile?
    private static var didConfigureStorage = false
  #endif

  public static func configureApplicationStorage(
    applicationSupportDirectory: URL, bundleIdentifier: String
  ) {
    #if !LDTX_DISTRIBUTION
      guard !didConfigureStorage else { return }
      didConfigureStorage = true
      if let url = existingApplicationFile(
        applicationSupportDirectory: applicationSupportDirectory, bundleIdentifier: bundleIdentifier
      ) {
        applicationFile = YouTubeAuthFile(url: url)
      }
    #endif
  }

  static func existingApplicationFile(
    applicationSupportDirectory: URL, bundleIdentifier: String
  ) -> URL? {
    #if !LDTX_DISTRIBUTION
      let url = applicationSupportDirectory.appendingPathComponent(bundleIdentifier)
        .appendingPathComponent(".YouTubeAuth")
      return FileManager.default.fileExists(atPath: url.path) ? url : nil
    #else
      return nil
    #endif
  }

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
  private let authorizationPresenter = LoopbackOAuthAuthorizationPresenter()

  public init(
    authorizationStore: YouTubeAuthorizationStore? = nil,
    oauthClientStore: OAuthClientConfigurationStore? = nil
  ) {
    #if !LDTX_DISTRIBUTION
      if let file = Self.applicationFile {
        self.authorizationStore = authorizationStore ?? YouTubeAuthorizationStore(file: file)
        self.oauthClientStore = oauthClientStore ?? OAuthClientConfigurationStore(file: file)
        return
      }
    #endif
    self.authorizationStore = authorizationStore ?? YouTubeAuthorizationStore()
    self.oauthClientStore = oauthClientStore ?? OAuthClientConfigurationStore()
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

  /// Restores OAuth client configuration and authorization from the configured stores.
  public func restoreStoredAuthorization() async throws -> AuthorizationRestoreResult {
    guard let configuration = try restorePersistedOAuthClient()?.configuration else {
      throw YouTubeAuthorizationServiceError.missingOAuthConfiguration
    }
    return try await withCheckedThrowingContinuation { continuation in
      restoreStoredAuthorization(configuration: configuration) { result in
        continuation.resume(with: result)
      }
    }
  }

  /// Gets a fresh access token using the configured credential stores.
  public func validAccessToken() async throws -> String {
    guard let configuration = try restorePersistedOAuthClient()?.configuration else {
      throw YouTubeAuthorizationServiceError.missingOAuthConfiguration
    }
    return try await withCheckedThrowingContinuation { continuation in
      validAccessToken(configuration: configuration) { result in
        continuation.resume(with: result)
      }
    }
  }

  public func authorize(
    configuration: GoogleOAuthClientConfiguration,
    completionHandler:
      @escaping @MainActor @Sendable (Result<AuthorizationResult, any Error>) -> Void
  ) {
    authorizationPresenter.authorize(
      requestBuilder: { redirectURI, state, challenge in
        try makeAuthorizationURL(
          configuration: configuration,
          redirectURI: redirectURI,
          state: state,
          codeChallenge: challenge)
      },
      completionHandler: { result in
        switch result {
        case .failure(let error):
          completionHandler(.failure(error))
        case .success(let grant):
          Task { @MainActor in
            do {
              let state = try await exchangeAuthorizationCode(grant, configuration: configuration)
              try authorizationStore.save(state, clientID: configuration.clientID)
              completionHandler(.success(AuthorizationResult(accessToken: state.accessToken)))
            } catch {
              completionHandler(.failure(error))
            }
          }
        }
      }
    )
  }

  public func authorize(configuration: GoogleOAuthClientConfiguration) async throws
    -> AuthorizationResult
  {
    try await withCheckedThrowingContinuation { continuation in
      authorize(configuration: configuration) { result in
        continuation.resume(with: result)
      }
    }
  }

  public func cancelAuthorization() {
    authorizationPresenter.cancelAuthorization()
  }

  public func restoreStoredAuthorization(
    configuration: GoogleOAuthClientConfiguration,
    completionHandler:
      @escaping @MainActor @Sendable (Result<AuthorizationRestoreResult, any Error>) -> Void
  ) {
    let authState: YouTubeAuthorizationState
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
    Task { @MainActor in
      do {
        let token = try await freshAccessToken(for: authState, configuration: configuration)
        completionHandler(.success(.authorized(accessToken: token)))
      } catch {
        completionHandler(.failure(error))
      }
    }
  }

  public func restoreStoredAuthorization(
    configuration: GoogleOAuthClientConfiguration
  ) async throws -> AuthorizationRestoreResult {
    try await withCheckedThrowingContinuation { continuation in
      restoreStoredAuthorization(configuration: configuration) { result in
        continuation.resume(with: result)
      }
    }
  }

  public func validAccessToken(
    configuration: GoogleOAuthClientConfiguration,
    completionHandler: @escaping @MainActor @Sendable (Result<String, any Error>) -> Void
  ) {
    let authState: YouTubeAuthorizationState
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
    Task { @MainActor in
      do {
        completionHandler(
          .success(try await freshAccessToken(for: authState, configuration: configuration)))
      } catch {
        completionHandler(.failure(error))
      }
    }
  }

  private func makeAuthorizationURL(
    configuration: GoogleOAuthClientConfiguration,
    redirectURI: URL,
    state: String,
    codeChallenge: String
  ) throws -> URL {
    guard configuration.authURI.scheme?.lowercased() == "https",
      var components = URLComponents(url: configuration.authURI, resolvingAgainstBaseURL: false)
    else {
      throw YouTubeAuthorizationServiceError.invalidAuthorizationEndpoint
    }
    var items = components.queryItems ?? []
    items.append(contentsOf: [
      URLQueryItem(name: "client_id", value: configuration.clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: YouTubeLiveScope.manageLiveStreaming),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: codeChallenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "prompt", value: "consent"),
    ])
    components.queryItems = items
    guard let url = components.url else {
      throw YouTubeAuthorizationServiceError.invalidAuthorizationEndpoint
    }
    return url
  }

  private func exchangeAuthorizationCode(
    _ grant: LoopbackOAuthAuthorizationPresenter.AuthorizationGrant,
    configuration: GoogleOAuthClientConfiguration
  ) async throws -> YouTubeAuthorizationState {
    var parameters = [
      "client_id": configuration.clientID,
      "code": grant.code,
      "code_verifier": grant.codeVerifier,
      "grant_type": "authorization_code",
      "redirect_uri": grant.redirectURI.absoluteString,
    ]
    if let secret = configuration.clientSecret { parameters["client_secret"] = secret }
    let response = try await requestToken(parameters, configuration: configuration)
    guard let refreshToken = response.refreshToken else {
      throw YouTubeAuthorizationServiceError.authorizationDidNotReturnRefreshToken
    }
    return YouTubeAuthorizationState(
      accessToken: response.accessToken,
      refreshToken: refreshToken,
      expirationDate: Date().addingTimeInterval(response.expiresIn))
  }

  private func freshAccessToken(
    for authState: YouTubeAuthorizationState,
    configuration: GoogleOAuthClientConfiguration
  ) async throws -> String {
    if authState.expirationDate > Date().addingTimeInterval(60) { return authState.accessToken }
    guard let refreshToken = authState.refreshToken else {
      throw YouTubeAuthorizationServiceError.missingAuthorization
    }
    var parameters = [
      "client_id": configuration.clientID,
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
    ]
    if let secret = configuration.clientSecret { parameters["client_secret"] = secret }
    let response = try await requestToken(parameters, configuration: configuration)
    var refreshedState = authState
    refreshedState.accessToken = response.accessToken
    refreshedState.expirationDate = Date().addingTimeInterval(response.expiresIn)
    if let newRefreshToken = response.refreshToken { refreshedState.refreshToken = newRefreshToken }
    try authorizationStore.save(refreshedState, clientID: configuration.clientID)
    return refreshedState.accessToken
  }

  private func requestToken(
    _ parameters: [String: String], configuration: GoogleOAuthClientConfiguration
  ) async throws -> OAuthTokenResponse {
    guard configuration.tokenURI.scheme?.lowercased() == "https" else {
      throw YouTubeAuthorizationServiceError.invalidTokenEndpoint
    }
    var components = URLComponents()
    components.queryItems = parameters.keys.sorted().map {
      URLQueryItem(name: $0, value: parameters[$0])
    }
    guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
      throw YouTubeAuthorizationServiceError.invalidTokenResponse
    }
    var request = URLRequest(url: configuration.tokenURI)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = body
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode)
    else {
      throw YouTubeAuthorizationServiceError.tokenRequestFailed
    }
    do {
      return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
    } catch {
      throw YouTubeAuthorizationServiceError.invalidTokenResponse
    }
  }
}

private struct OAuthTokenResponse: Decodable {
  var accessToken: String
  var expiresIn: TimeInterval
  var refreshToken: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case expiresIn = "expires_in"
    case refreshToken = "refresh_token"
  }
}

public enum YouTubeAuthorizationServiceError: Error, LocalizedError {
  case missingAuthorization
  case missingOAuthConfiguration
  case invalidAuthorizationEndpoint
  case invalidTokenEndpoint
  case invalidTokenResponse
  case tokenRequestFailed
  case authorizationDidNotReturnRefreshToken

  public var errorDescription: String? {
    switch self {
    case .missingAuthorization:
      "Authorize YouTube before creating a stream."
    case .missingOAuthConfiguration:
      "Import a YouTube OAuth client before authorizing."
    case .invalidAuthorizationEndpoint:
      "The OAuth authorization endpoint must be a valid HTTPS URL."
    case .invalidTokenEndpoint:
      "The OAuth token endpoint must be a valid HTTPS URL."
    case .invalidTokenResponse:
      "The OAuth token endpoint returned an invalid response."
    case .tokenRequestFailed:
      "The OAuth token request failed."
    case .authorizationDidNotReturnRefreshToken:
      "Google did not return a refresh token. Authorize YouTube again."
    }
  }
}
