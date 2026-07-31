// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@testable import LDTXAppCore
import Foundation
import LDTXYouTubeAuth
import Testing

@MainActor
struct YouTubeAuthStateTests {
  @Test func authorizeIsSingleFlightAndCanRunAgainAfterCompletion() async throws {
    var invocationCount = 0
    let state = YouTubeAuthState(
      youtubeClientService: .preview,
      authorizeOperation: { _ in
        invocationCount += 1
        throw TestError.expected
      }
    )
    let configuration = GoogleOAuthClientConfiguration(
      clientID: "client-id",
      clientSecret: nil,
      authURI: try #require(URL(string: "https://example.com/auth")),
      tokenURI: try #require(URL(string: "https://example.com/token")),
      redirectURIs: [try #require(URL(string: "example:/callback"))]
    )

    state.authorize(configuration: configuration)
    state.authorize(configuration: configuration)

    #expect(state.isAuthorizing)
    try await waitUntil { invocationCount == 1 && !state.isAuthorizing }
    #expect(invocationCount == 1)
    #expect(!state.isAuthorizing)

    state.authorize(configuration: configuration)
    try await waitUntil { invocationCount == 2 && !state.isAuthorizing }
    #expect(invocationCount == 2)
    #expect(!state.isAuthorizing)
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

  private enum TestError: Error {
    case expected
  }
}
