// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LDTXSettingsApplet
import LDTXYouTubeAuth
import Testing

@Suite
@MainActor
struct YouTubeAuthStateIntegrationTestSuite {
  @Test func settingsInstancesRestoreIndependentStateFromSharedProvider() async throws {
    let provider = TestAuthorizationProvider()
    provider.configuration = GoogleOAuthClientConfiguration(
      clientID: "client-id",
      clientSecret: nil,
      authURI: try #require(URL(string: "https://example.com/auth")),
      tokenURI: try #require(URL(string: "https://example.com/token")),
      redirectURIs: []
    )
    let first = SettingsAccountModel(authorizationService: provider)
    let second = SettingsAccountModel(authorizationService: provider)

    first.restoreAuthorization()
    second.restoreAuthorization()
    try await waitUntil {
      first.authorizationStatus == "Authorized"
        && second.authorizationStatus == "Authorized"
    }

    #expect(first !== second)
    #expect(first.oauthStatus == second.oauthStatus)
    #expect(first.authorizationStatus == second.authorizationStatus)
  }

  @Test func importingOAuthClientUpdatesOnlyTheSettingsInstance() async throws {
    let provider = TestAuthorizationProvider()
    let first = SettingsAccountModel(authorizationService: provider)
    let second = SettingsAccountModel(authorizationService: provider)
    let configuration = GoogleOAuthClientConfiguration(
      clientID: "client-id",
      clientSecret: nil,
      authURI: try #require(URL(string: "https://example.com/auth")),
      tokenURI: try #require(URL(string: "https://example.com/token")),
      redirectURIs: []
    )

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try Data("oauth".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(first.loadOAuthClient(from: url))
    #expect(provider.configuration == configuration)
    #expect(second.oauthStatus == "No OAuth client")
  }

  @Test func authorizationRestoreFailurePreservesLoadedOAuthClientStatus() async throws {
    let provider = TestAuthorizationProvider()
    provider.configuration = GoogleOAuthClientConfiguration(
      clientID: "client-id",
      clientSecret: nil,
      authURI: try #require(URL(string: "https://example.com/auth")),
      tokenURI: try #require(URL(string: "https://example.com/token")),
      redirectURIs: []
    )
    provider.restoreAuthorizationError = NSError(
      domain: "AuthorizationRestoreTest", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Stored authorization is unavailable"])
    let model = SettingsAccountModel(authorizationService: provider)

    model.restoreAuthorization()
    try await waitUntil {
      model.authorizationStatus.contains("Stored authorization is unavailable")
    }

    #expect(model.oauthStatus == "OAuth client loaded: loaded")
    #expect(model.canAuthorize)
  }

  @Test func olderAuthorizationRestoreCannotOverwriteImportedOAuthClientState() async throws {
    let provider = TestAuthorizationProvider()
    provider.configuration = try makeConfiguration(clientID: "client-a")
    provider.suspendedClientID = "client-a"
    provider.restoreAuthorizationError = NSError(
      domain: "AuthorizationRestoreTest", code: 2,
      userInfo: [NSLocalizedDescriptionKey: "Client B restore failed"])
    let model = SettingsAccountModel(authorizationService: provider)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try Data("oauth".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    model.restoreAuthorization()
    try await waitUntil { provider.hasPendingRestore(for: "client-a") }
    #expect(model.loadOAuthClient(from: url))
    model.restoreAuthorization()
    try await waitUntil {
      model.authorizationStatus.contains("Client B restore failed")
    }

    provider.completePendingRestore(
      for: "client-a", with: .success(.authorized(accessToken: "stale-token")))
    try await Task.sleep(for: .milliseconds(30))

    #expect(model.authorizationStatus == "Authorization restore failed: Client B restore failed")
    #expect(model.oauthStatus == "OAuth client loaded: loaded")
  }

  @Test(arguments: [(true, false), (false, true)])
  func testModesDoNotRestoreOrPersistYouTubeAuthorization(
    isUnitTesting: Bool,
    isUITesting: Bool
  ) async throws {
    let provider = SettingsAuthorizationServiceFactory.make(
      isUnitTesting: isUnitTesting, isUITesting: isUITesting)
    let configuration = GoogleOAuthClientConfiguration(
      clientID: "test-client",
      clientSecret: nil,
      authURI: try #require(URL(string: "https://example.com/auth")),
      tokenURI: try #require(URL(string: "https://example.com/token")),
      redirectURIs: []
    )

    #expect(try provider.restorePersistedOAuthClient() == nil)
    let restoredAuthorization = try await provider.restoreStoredAuthorization(
      configuration: configuration)
    if case .notAuthorized = restoredAuthorization {
    } else {
      Issue.record("Test mode unexpectedly restored a persisted authorization")
    }
    #expect(throws: SettingsAuthorizationServiceError.unavailableInTestMode) {
      try provider.loadOAuthClient(data: Data())
    }
    await #expect(throws: SettingsAuthorizationServiceError.unavailableInTestMode) {
      try await provider.authorize(configuration: configuration)
    }
  }

  private func makeConfiguration(clientID: String) throws -> GoogleOAuthClientConfiguration {
    GoogleOAuthClientConfiguration(
      clientID: clientID,
      clientSecret: nil,
      authURI: try #require(URL(string: "https://example.com/auth")),
      tokenURI: try #require(URL(string: "https://example.com/token")),
      redirectURIs: []
    )
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
      guard ContinuousClock.now < deadline else {
        Issue.record("Timed out waiting for condition")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private final class TestAuthorizationProvider: SettingsAuthorizationProviding {
    var configuration: GoogleOAuthClientConfiguration?
    var restoreAuthorizationError: (any Error)?
    var suspendedClientID: String?
    private var pendingRestores:
      [String: CheckedContinuation<
        YouTubeAuthorizationService.AuthorizationRestoreResult, any Error
      >] = [:]

    func hasPendingRestore(for clientID: String) -> Bool {
      pendingRestores[clientID] != nil
    }

    func completePendingRestore(
      for clientID: String,
      with result: Result<YouTubeAuthorizationService.AuthorizationRestoreResult, any Error>
    ) {
      pendingRestores.removeValue(forKey: clientID)?.resume(with: result)
    }

    func restorePersistedOAuthClient() throws -> GoogleOAuthClientConfiguration? {
      configuration
    }

    func restoreStoredAuthorization(
      configuration: GoogleOAuthClientConfiguration
    ) async throws -> YouTubeAuthorizationService.AuthorizationRestoreResult {
      if configuration.clientID == suspendedClientID {
        return try await withCheckedThrowingContinuation { continuation in
          pendingRestores[configuration.clientID] = continuation
        }
      }
      if let restoreAuthorizationError { throw restoreAuthorizationError }
      return .authorized(accessToken: "access-token")
    }

    func loadOAuthClient(data: Data) throws -> GoogleOAuthClientConfiguration {
      let configuration = GoogleOAuthClientConfiguration(
        clientID: "client-id",
        clientSecret: nil,
        authURI: URL(string: "https://example.com/auth")!,
        tokenURI: URL(string: "https://example.com/token")!,
        redirectURIs: []
      )
      self.configuration = configuration
      return configuration
    }

    func authorize(configuration: GoogleOAuthClientConfiguration) async throws {}
    func cancelAuthorization() {}
  }
}
