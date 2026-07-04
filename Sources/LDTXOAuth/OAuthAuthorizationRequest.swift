// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct OAuthAuthorizationRequest: Sendable, Equatable {
    public var configuration: GoogleOAuthClientConfiguration
    public var redirectURI: URL
    public var scopes: [String]
    public var state: String
    public var codeChallenge: String
    public var additionalParameters: [String: String]

    public init(
        configuration: GoogleOAuthClientConfiguration,
        redirectURI: URL,
        scopes: [String],
        state: String,
        codeChallenge: String,
        additionalParameters: [String: String] = ["access_type": "offline", "prompt": "consent"]
    ) {
        self.configuration = configuration
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.state = state
        self.codeChallenge = codeChallenge
        self.additionalParameters = additionalParameters
    }

    public var url: URL {
        var components = URLComponents(url: configuration.authURI, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        items.append(contentsOf: additionalParameters.sorted(by: { $0.key < $1.key }).map(URLQueryItem.init(name:value:)))
        components.queryItems = items
        return components.url!
    }
}
