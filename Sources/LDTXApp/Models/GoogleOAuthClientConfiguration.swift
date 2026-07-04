// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct GoogleOAuthClientConfiguration: Sendable, Equatable {
    var clientID: String
    var clientSecret: String?
    var authURI: URL
    var tokenURI: URL
    var redirectURIs: [URL]

    init(clientID: String, clientSecret: String?, authURI: URL, tokenURI: URL, redirectURIs: [URL]) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.authURI = authURI
        self.tokenURI = tokenURI
        self.redirectURIs = redirectURIs
    }

    init(data: Data) throws {
        let root = try JSONDecoder().decode(GoogleOAuthClientJSON.self, from: data)
        guard let payload = root.installed ?? root.web else {
            throw GoogleOAuthClientConfigurationError.missingClientPayload
        }
        guard let authURI = URL(string: payload.authURI), let tokenURI = URL(string: payload.tokenURI) else {
            throw GoogleOAuthClientConfigurationError.invalidEndpoint
        }
        let redirectURIs = payload.redirectURIs.compactMap(URL.init(string:))
        guard !redirectURIs.isEmpty else {
            throw GoogleOAuthClientConfigurationError.missingRedirectURI
        }

        self.clientID = payload.clientID
        self.clientSecret = payload.clientSecret
        self.authURI = authURI
        self.tokenURI = tokenURI
        self.redirectURIs = redirectURIs
    }
}

enum GoogleOAuthClientConfigurationError: Error, Equatable, LocalizedError {
    case missingClientPayload
    case invalidEndpoint
    case missingRedirectURI

    var errorDescription: String? {
        switch self {
        case .missingClientPayload:
            "The OAuth client JSON does not contain an installed or web client payload."
        case .invalidEndpoint:
            "The OAuth client JSON contains an invalid authorization or token endpoint."
        case .missingRedirectURI:
            "The OAuth client JSON does not contain a redirect URI."
        }
    }
}

private struct GoogleOAuthClientJSON: Decodable {
    var installed: GoogleOAuthClientPayload?
    var web: GoogleOAuthClientPayload?
}

private struct GoogleOAuthClientPayload: Decodable {
    var clientID: String
    var clientSecret: String?
    var authURI: String
    var tokenURI: String
    var redirectURIs: [String]

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case authURI = "auth_uri"
        case tokenURI = "token_uri"
        case redirectURIs = "redirect_uris"
    }
}
