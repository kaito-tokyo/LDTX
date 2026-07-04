// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXOAuth
import LDTXYouTube

@MainActor
final class YouTubeAuthState: ObservableObject {
    @Published var status = "Not authorized"
    @Published private(set) var channelID: String?

    private let youtubeClientService: YouTubeClientService
    private var clientID: String?
    private var tokenResponse: OAuthTokenResponse?
    private var storedOAuthToken: StoredOAuthToken?

    init(youtubeClientService: YouTubeClientService) {
        self.youtubeClientService = youtubeClientService
    }

    func restore(for configuration: GoogleOAuthClientConfiguration?) {
        Task {
            await restoreStoredAuthorization(for: configuration)
        }
    }

    func authorize(configuration: GoogleOAuthClientConfiguration?) {
        Task {
            await runAuthorization(configuration: configuration)
        }
    }

    func validAccessToken(configuration: GoogleOAuthClientConfiguration?) async throws -> String {
        guard let configuration else {
            throw YouTubeClientServiceError.missingOAuthConfiguration
        }
        prepareForClient(configuration)
        let result = try await youtubeClientService.validAccessToken(
            configuration: configuration,
            tokenResponse: tokenResponse,
            storedOAuthToken: storedOAuthToken
        )
        if let tokenResponse = result.tokenResponse {
            self.tokenResponse = tokenResponse
        }
        if let storedToken = result.storedToken {
            storedOAuthToken = storedToken
        }
        status = "Authorized"
        return result.accessToken
    }

    func refreshChannelID(configuration: GoogleOAuthClientConfiguration?) {
        Task {
            do {
                let accessToken = try await validAccessToken(configuration: configuration)
                await loadChannelID(accessToken: accessToken, authorizedStatus: status)
            } catch {
                channelID = nil
                status = "Channel ID unavailable: \(error.localizedDescription)"
            }
        }
    }

    private func runAuthorization(configuration: GoogleOAuthClientConfiguration?) async {
        status = "Authorizing..."
        do {
            guard let configuration else {
                throw YouTubeClientServiceError.missingOAuthConfiguration
            }
            prepareForClient(configuration)
            let result = try await youtubeClientService.authorize(configuration: configuration)
            tokenResponse = result.tokenResponse
            storedOAuthToken = result.storedToken
            await loadChannelID(
                accessToken: result.tokenResponse.accessToken,
                authorizedStatus: "Authorized (Keychain)"
            )
        } catch {
            channelID = nil
            status = "Authorization failed: \(error.localizedDescription)"
        }
    }

    private func restoreStoredAuthorization(for configuration: GoogleOAuthClientConfiguration?) async {
        do {
            guard let configuration else {
                reset()
                return
            }
            prepareForClient(configuration)
            let result = try await youtubeClientService.restoreStoredAuthorization(
                configuration: configuration
            )
            switch result {
            case .notAuthorized:
                status = "Not authorized"
            case let .restored(storedToken):
                tokenResponse = storedToken.response
                storedOAuthToken = storedToken
                await loadChannelID(
                    accessToken: storedToken.response.accessToken,
                    authorizedStatus: "Authorized"
                )
            case .expired:
                channelID = nil
                status = "Authorization expired"
            case let .refreshed(storedToken):
                tokenResponse = storedToken.response
                storedOAuthToken = storedToken
                await loadChannelID(
                    accessToken: storedToken.response.accessToken,
                    authorizedStatus: "Authorized (Keychain)"
                )
            }
        } catch {
            channelID = nil
            status = "Authorization restore failed: \(error.localizedDescription)"
        }
    }

    private func prepareForClient(_ configuration: GoogleOAuthClientConfiguration) {
        guard clientID != configuration.clientID else {
            return
        }
        clientID = configuration.clientID
        tokenResponse = nil
        storedOAuthToken = nil
        channelID = nil
        status = "Not authorized"
    }

    private func reset() {
        clientID = nil
        tokenResponse = nil
        storedOAuthToken = nil
        channelID = nil
        status = "Not authorized"
    }

    private func loadChannelID(accessToken: String, authorizedStatus: String) async {
        do {
            if let channelID = try await youtubeClientService.authenticatedChannelID(accessToken: accessToken) {
                self.channelID = channelID
                status = "\(authorizedStatus), channel \(redactedChannelID(channelID))"
            } else {
                channelID = nil
                status = "\(authorizedStatus), no channel"
            }
        } catch {
            channelID = nil
            status = "\(authorizedStatus), channel unavailable: \(error.localizedDescription)"
        }
    }

    private func redactedChannelID(_ channelID: String) -> String {
        guard channelID.count > 8 else {
            return channelID
        }
        return "\(channelID.prefix(8))..."
    }
}
