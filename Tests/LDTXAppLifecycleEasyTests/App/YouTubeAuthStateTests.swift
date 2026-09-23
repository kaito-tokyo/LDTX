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

    func restorePersistedOAuthClient() throws -> GoogleOAuthClientConfiguration? {
      configuration
    }

    func restoreStoredAuthorization(
      configuration: GoogleOAuthClientConfiguration
    ) async throws -> YouTubeAuthorizationService.AuthorizationRestoreResult {
      .authorized(accessToken: "access-token")
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
