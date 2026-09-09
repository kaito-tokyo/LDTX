// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AppAuth
import Foundation
import Testing

@testable import LDTXYouTubeAuth

@Suite
struct GoogleOAuthLoopbackListenerEasyTests {
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
}
