// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
 import LDTXCapture
 import LDTXDash
 import LDTXMedia
 import LDTXOAuth
 import LDTXSupport
 import LDTXYouTube

final class OAuthTests: XCTestCase {
    func testPKCEChallengeMatchesRFC7636Example() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

        let challenge = PKCE.challenge(for: verifier)

        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testParsesGoogleInstalledAppClientJSON() throws {
        let json = """
        {
          "installed": {
            "client_id": "example.apps.googleusercontent.com",
            "project_id": "project",
            "auth_uri": "https://accounts.google.com/o/oauth2/auth",
            "token_uri": "https://oauth2.googleapis.com/token",
            "client_secret": "not-asserted",
            "redirect_uris": ["http://localhost"]
          }
        }
        """

        let configuration = try GoogleOAuthClientConfiguration(data: Data(json.utf8))

        XCTAssertEqual(configuration.clientID, "example.apps.googleusercontent.com")
        XCTAssertEqual(configuration.authURI.absoluteString, "https://accounts.google.com/o/oauth2/auth")
        XCTAssertEqual(configuration.tokenURI.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(configuration.redirectURIs.map(\.absoluteString), ["http://localhost"])
    }

    func testOAuthClientConfigurationStorePersistsClientJSON() throws {
        let service = "LDTXCoreTests.oauth-client.\(UUID().uuidString)"
        let account = "client-json"
        let store = OAuthClientConfigurationStore(
            service: service,
            account: account
        )
        defer { try? store.delete() }
        let json = """
        {
          "installed": {
            "client_id": "stored.apps.googleusercontent.com",
            "auth_uri": "https://accounts.google.com/o/oauth2/auth",
            "token_uri": "https://oauth2.googleapis.com/token",
            "client_secret": "not-asserted",
            "redirect_uris": ["http://localhost"]
          }
        }
        """

        try store.save(Data(json.utf8))
        let configuration = try store.load()

        XCTAssertEqual(configuration?.clientID, "stored.apps.googleusercontent.com")
        XCTAssertEqual(configuration?.clientSecret, "not-asserted")
        XCTAssertEqual(configuration?.redirectURIs.map(\.absoluteString), ["http://localhost"])
    }

    func testOAuthTokenStorePersistsTokenInKeychain() throws {
        let service = "LDTXCoreTests.oauth-token.\(UUID().uuidString)"
        let clientID = "client-id"
        let store = OAuthTokenStore(
            service: service
        )
        defer { try? store.delete(clientID: clientID) }
        let token = StoredOAuthToken(
            response: OAuthTokenResponse(
                accessToken: "access-token",
                expiresIn: 3_600,
                refreshToken: "refresh-token"
            ),
            issuedAt: Date(timeIntervalSince1970: 100)
        )

        try store.save(token, clientID: clientID)
        let loadedToken = try store.load(clientID: clientID)

        XCTAssertEqual(loadedToken, token)
    }

    func testAuthorizationURLContainsPKCEParameters() throws {
        let configuration = GoogleOAuthClientConfiguration(
            clientID: "client-id",
            clientSecret: nil,
            authURI: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenURI: URL(string: "https://oauth2.googleapis.com/token")!,
            redirectURIs: [URL(string: "http://localhost")!]
        )
        let request = OAuthAuthorizationRequest(
            configuration: configuration,
            redirectURI: URL(string: "http://127.0.0.1:53682/oauth2/callback")!,
            scopes: [YouTubeLiveScope.manageLiveStreaming],
            state: "state",
            codeChallenge: "challenge"
        )

        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        let items = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["client_id"], "client-id")
        XCTAssertEqual(items["code_challenge"], "challenge")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["scope"], YouTubeLiveScope.manageLiveStreaming)
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(items["prompt"], "consent")
    }

    func testStoredOAuthTokenPreservesRefreshTokenWhenRefreshingAccessToken() {
        let stored = StoredOAuthToken(
            response: OAuthTokenResponse(
                accessToken: "old-access-token",
                expiresIn: 1,
                refreshToken: "refresh-token"
            ),
            issuedAt: Date(timeIntervalSince1970: 100)
        )
        let refreshed = OAuthTokenResponse(
            accessToken: "new-access-token",
            expiresIn: 3_600,
            refreshToken: nil
        )

        let updated = stored.replacingResponseAfterRefresh(
            refreshed,
            issuedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(updated.response.accessToken, "new-access-token")
        XCTAssertEqual(updated.response.refreshToken, "refresh-token")
        XCTAssertEqual(updated.issuedAt, Date(timeIntervalSince1970: 200))
    }

    func testStoredOAuthTokenValidityUsesIssuedAtAndLeeway() {
        let stored = StoredOAuthToken(
            response: OAuthTokenResponse(accessToken: "access-token", expiresIn: 120),
            issuedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertTrue(stored.isAccessTokenValid(now: Date(timeIntervalSince1970: 150), leeway: 60))
        XCTAssertFalse(stored.isAccessTokenValid(now: Date(timeIntervalSince1970: 170), leeway: 60))
    }
}
