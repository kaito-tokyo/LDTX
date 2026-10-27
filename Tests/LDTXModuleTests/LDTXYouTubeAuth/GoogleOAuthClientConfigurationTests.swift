// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LDTXYouTubeAuth
import Testing

@Suite(.tags(.easy))
struct GoogleOAuthClientConfigurationUnitTestSuite {
  @Test("LUB-1018: Buffers fragmented callback headers with a size limit")
  func buffersFragmentedCallbackHeaders() {
    var headers = OAuthCallbackHeaders()
    let firstAccepted = headers.append(Data("GET /oauth2callback HTTP/1.1\r\nHo".utf8))
    #expect(firstAccepted)
    #expect(!headers.isComplete)
    let secondAccepted = headers.append(Data("st: 127.0.0.1:1234\r\n\r".utf8))
    #expect(secondAccepted)
    #expect(!headers.isComplete)
    let thirdAccepted = headers.append(Data("\n".utf8))
    #expect(thirdAccepted)
    #expect(headers.isComplete)

    var oversized = OAuthCallbackHeaders()
    let limitAccepted = oversized.append(
      Data(repeating: 65, count: OAuthCallbackHeaders.maximumSize))
    #expect(limitAccepted)
    #expect(!oversized.isComplete)
    let overflowAccepted = oversized.append(Data([65]))
    #expect(!overflowAccepted)
  }

  @Test("LUB-1018: Form encodes token credentials")
  func formEncodesTokenCredentials() throws {
    let data = encodeOAuthForm(["client_secret": "a+b &c=雪"])
    let body = try #require(String(data: data, encoding: .utf8))
    #expect(body == "client_secret=a%2Bb+%26c%3D%E9%9B%AA")
  }

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
    let listenerURL = try #require(
      URL(string: "http://127.0.0.1:49152/oauth2callback"))

    let callbackURL = try LoopbackOAuthRedirect.validate(listenerURL: listenerURL)

    #expect(callbackURL == listenerURL)
  }

  @Test("LUB-1018: Rejects non i pv4 loopback listener") func rejectsNonIPv4LoopbackListener()
    throws
  {
    let listenerURL = try #require(URL(string: "http://[::1]:49152/oauth2callback"))

    #expect(throws: LoopbackOAuthAuthorizationError.self) {
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
