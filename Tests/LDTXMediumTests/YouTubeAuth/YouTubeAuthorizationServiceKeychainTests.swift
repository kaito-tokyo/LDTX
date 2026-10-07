// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LDTXYouTubeAuth
import Testing

@Suite
struct YouTubeAuthorizationServiceIntegrationTestSuite {
  @Test @MainActor func keychainOnlyAuthorizationReportsMissingOAuthConfiguration() async throws {
    let suffix = UUID().uuidString
    let oauthStore = OAuthClientConfigurationStore(
      service: "tokyo.kaito.ldtx.tests.oauth-client.\(suffix)", account: "oauth-client")
    let authorizationStore = YouTubeAuthorizationStore(
      service: "tokyo.kaito.ldtx.tests.youtube-auth.\(suffix)")
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
