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
        try await Task.sleep(for: .milliseconds(50))
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
    try await Task.sleep(for: .milliseconds(100))
    #expect(invocationCount == 1)
    #expect(!state.isAuthorizing)

    state.authorize(configuration: configuration)
    try await Task.sleep(for: .milliseconds(100))
    #expect(invocationCount == 2)
    #expect(!state.isAuthorizing)
  }

  private enum TestError: Error {
    case expected
  }
}
