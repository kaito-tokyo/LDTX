// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@testable import LDTX
import Foundation
import LDTXYouTubeAuth
import XCTest

@MainActor
final class YouTubeAuthStateTests: XCTestCase {
  func testAuthorizeIsSingleFlightAndCanRunAgainAfterCompletion() async throws {
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
      authURI: try XCTUnwrap(URL(string: "https://example.com/auth")),
      tokenURI: try XCTUnwrap(URL(string: "https://example.com/token")),
      redirectURIs: [try XCTUnwrap(URL(string: "example:/callback"))]
    )

    state.authorize(configuration: configuration)
    state.authorize(configuration: configuration)

    XCTAssertTrue(state.isAuthorizing)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(invocationCount, 1)
    XCTAssertFalse(state.isAuthorizing)

    state.authorize(configuration: configuration)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(invocationCount, 2)
    XCTAssertFalse(state.isAuthorizing)
  }

  private enum TestError: Error {
    case expected
  }
}
