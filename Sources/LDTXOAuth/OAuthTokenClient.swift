// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXSupport

public struct OAuthTokenResponse: Codable, Equatable, Sendable {
    public var accessToken: String
    public var expiresIn: Int?
    public var refreshToken: String?
    public var scope: String?
    public var tokenType: String

    public init(
        accessToken: String,
        expiresIn: Int? = nil,
        refreshToken: String? = nil,
        scope: String? = nil,
        tokenType: String = "Bearer"
    ) {
        self.accessToken = accessToken
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.scope = scope
        self.tokenType = tokenType
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
    }
}

public enum OAuthTokenClientError: Error, Equatable, LocalizedError {
    case nonHTTPResponse
    case rejected(statusCode: Int, body: Data)

    public var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            "The OAuth token endpoint returned a non-HTTP response."
        case let .rejected(statusCode, _):
            "The OAuth token endpoint rejected the request with HTTP \(statusCode)."
        }
    }
}

public struct OAuthTokenClient: Sendable {
    public var session: any HTTPSession

    public init(session: any HTTPSession = URLSession.shared) {
        self.session = session
    }

    public func exchangeAuthorizationCode(
        _ code: String,
        verifier: String,
        redirectURI: URL,
        configuration: GoogleOAuthClientConfiguration
    ) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: configuration.tokenURI)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoder.encode([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", configuration.clientID),
            ("client_secret", configuration.clientSecret),
            ("redirect_uri", redirectURI.absoluteString),
            ("code_verifier", verifier)
        ])

        return try await send(request)
    }

    public func refreshAccessToken(
        _ refreshToken: String,
        configuration: GoogleOAuthClientConfiguration
    ) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: configuration.tokenURI)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoder.encode([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", configuration.clientID),
            ("client_secret", configuration.clientSecret)
        ])

        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> OAuthTokenResponse {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthTokenClientError.nonHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OAuthTokenClientError.rejected(statusCode: httpResponse.statusCode, body: data)
        }
        return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
    }
}
