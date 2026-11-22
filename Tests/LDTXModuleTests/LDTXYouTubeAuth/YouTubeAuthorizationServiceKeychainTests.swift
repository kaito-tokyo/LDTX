// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LDTXYouTubeAuth
import Testing

@Suite(.tags(.easy))
struct YouTubeAuthorizationServiceIntegrationTestSuite {
  @Test("LUB-1018: Keychain only authorization reports missing o auth configuration") @MainActor
  func keychainOnlyAuthorizationReportsMissingOAuthConfiguration() async throws {
    // Hostless tests have no Keychain entitlement, so the data-protection keychain is faked.
    let keychain = FakeYouTubeKeychain()
    let oauthStore = OAuthClientConfigurationStore(
      service: "tokyo.kaito.ldtx.tests.oauth-client", account: "oauth-client",
      keychainOperations: keychain.operations)
    let authorizationStore = YouTubeAuthorizationStore(
      service: "tokyo.kaito.ldtx.tests.youtube-auth", keychainOperations: keychain.operations)
    let service = YouTubeAuthorizationService(
      authorizationStore: authorizationStore,
      oauthClientStore: oauthStore
    )
    defer { try? oauthStore.delete() }
    try authorizationStore.delete(clientID: "unused")

    await #expect(throws: YouTubeAuthorizationServiceError.missingOAuthConfiguration) {
      try await service.validAccessToken()
    }
  }
}
