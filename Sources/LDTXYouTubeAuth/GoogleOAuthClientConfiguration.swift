// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct GoogleOAuthClientConfiguration: Sendable, Equatable {
  public var clientID: String
  public var clientSecret: String?
  public var authURI: URL
  public var tokenURI: URL
  public var redirectURIs: [URL]

  public init(
    clientID: String, clientSecret: String?, authURI: URL, tokenURI: URL, redirectURIs: [URL]
  ) {
    self.clientID = clientID
    self.clientSecret = clientSecret
    self.authURI = authURI
    self.tokenURI = tokenURI
    self.redirectURIs = redirectURIs
  }

  public init(data: Data) throws {
    let root = try JSONDecoder().decode(GoogleOAuthClientJSON.self, from: data)
    guard let payload = root.installed else {
      if root.web != nil {
        throw GoogleOAuthClientConfigurationError.unsupportedClientType
      }
      throw GoogleOAuthClientConfigurationError.missingClientPayload
    }
    guard let authURI = URL(string: payload.authURI), let tokenURI = URL(string: payload.tokenURI)
    else {
      throw GoogleOAuthClientConfigurationError.invalidEndpoint
    }
    let redirectURIs = (payload.redirectURIs ?? []).compactMap(URL.init(string:))

    self.clientID = payload.clientID
    self.clientSecret = payload.clientSecret
    self.authURI = authURI
    self.tokenURI = tokenURI
    self.redirectURIs = redirectURIs
  }
}

public enum GoogleOAuthClientConfigurationError: Error, Equatable, LocalizedError {
  case missingClientPayload
  case invalidEndpoint
  case unsupportedClientType

  public var errorDescription: String? {
    switch self {
    case .missingClientPayload:
      "The OAuth client JSON does not contain a Desktop app client payload."
    case .invalidEndpoint:
      "The OAuth client JSON contains an invalid authorization or token endpoint."
    case .unsupportedClientType:
      "Use a Google OAuth client JSON whose application type is Desktop app."
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
  var redirectURIs: [String]?

  enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
    case clientSecret = "client_secret"
    case authURI = "auth_uri"
    case tokenURI = "token_uri"
    case redirectURIs = "redirect_uris"
  }
}
