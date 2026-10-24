// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AppAuth
import Foundation
@testable import LDTXYouTubeAuth
import Testing

@Suite(.tags(.easy))
struct GoogleOAuthClientConfigurationUnitTestSuite {
  @Test("LUB-1018: Accepts desktop client without configured redirect uri")
  func acceptsDesktopClientWithoutConfiguredRedirectURI() throws {
    let data = try #require(
      """
      {
        "installed": {
          "client_id": "desktop-client.apps.googleusercontent.com",
          "client_secret": "secret",
          "auth_uri": "https://accounts.google.com/o/oauth2/auth",
          "token_uri": "https://oauth2.googleapis.com/token"
        }
      }
      """.data(using: .utf8)
    )

    let configuration = try GoogleOAuthClientConfiguration(data: data)

    #expect(configuration.clientID == "desktop-client.apps.googleusercontent.com")
    #expect(configuration.redirectURIs.isEmpty)
  }

  @Test("LUB-1018: Uses exact i pv4 loopback listener URL as redirect uri")
  func usesExactIPv4LoopbackListenerURLAsRedirectURI() throws {
    let listenerURL = try #require(URL(string: "http://127.0.0.1:49152/"))

    let callbackURL = try LoopbackOAuthRedirect.validate(listenerURL: listenerURL)

    #expect(callbackURL == listenerURL)
  }

  @Test("LUB-1018: Rejects non i pv4 loopback listener") func rejectsNonIPv4LoopbackListener()
    throws
  {
    let listenerURL = try #require(URL(string: "http://[::1]:49152/"))

    #expect(throws: AppAuthAuthorizationPresenterError.self) {
      try LoopbackOAuthRedirect.validate(listenerURL: listenerURL)
    }
  }

  @Test("LUB-1018: Rejects web application client") func rejectsWebApplicationClient() throws {
    let data = try #require(
      """
      {
        "web": {
          "client_id": "web-client.apps.googleusercontent.com",
          "client_secret": "secret",
          "auth_uri": "https://accounts.google.com/o/oauth2/auth",
          "token_uri": "https://oauth2.googleapis.com/token",
          "redirect_uris": ["https://example.com/oauth/callback"]
        }
      }
      """.data(using: .utf8)
    )

    #expect(throws: GoogleOAuthClientConfigurationError.unsupportedClientType) {
      try GoogleOAuthClientConfiguration(data: data)
    }
  }
}
