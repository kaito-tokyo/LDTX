// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXYouTube

@MainActor
final class YouTubeAuthState: ObservableObject {
    @Published var status = "Not authorized"
    @Published private(set) var channelID: String?

    private let youtubeClientService: YouTubeClientService
    private var clientID: String?

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
        let accessToken = try await youtubeClientService.validAccessToken(configuration: configuration)
        status = "Authorized"
        return accessToken
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
            await loadChannelID(
                accessToken: result.accessToken,
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
            case let .authorized(accessToken):
                await loadChannelID(
                    accessToken: accessToken,
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
        channelID = nil
        status = "Not authorized"
    }

    private func reset() {
        clientID = nil
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
