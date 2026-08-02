// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AppAuth
import Foundation
import Testing

@testable import LDTXYouTubeAuth

struct GoogleOAuthClientConfigurationTests {
  @Test func acceptsDesktopClientWithoutConfiguredRedirectURI() throws {
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

  @Test func usesExactIPv4LoopbackListenerURLAsRedirectURI() throws {
    let listenerURL = try #require(URL(string: "http://127.0.0.1:49152/"))

    let callbackURL = try LoopbackOAuthRedirect.validate(listenerURL: listenerURL)

    #expect(callbackURL == listenerURL)
  }

  @Test func appAuthListenerChoosesRandomIPv4LoopbackPort() throws {
    let handler = OIDRedirectHTTPHandler(successURL: nil)
    var listenerError: NSError?
    let listenerURL = try #require(handler.startHTTPListener(&listenerError) as URL?)
    defer { handler.cancelHTTPListener() }

    #expect(listenerError == nil)
    #expect(listenerURL.host == "127.0.0.1")
    #expect((listenerURL.port ?? 0) > 0)
    #expect(try LoopbackOAuthRedirect.validate(listenerURL: listenerURL) == listenerURL)
  }

  @Test func rejectsNonIPv4LoopbackListener() throws {
    let listenerURL = try #require(URL(string: "http://[::1]:49152/"))

    #expect(throws: AppAuthAuthorizationPresenterError.self) {
      try LoopbackOAuthRedirect.validate(listenerURL: listenerURL)
    }
  }

  @Test func rejectsWebApplicationClient() throws {
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
