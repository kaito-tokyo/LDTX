// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXOAuth
import LDTXYouTube

@MainActor
final class OAuthClientState: ObservableObject {
    @Published var status = "No OAuth client"
    @Published var isImportingOAuthClient = false

    private let youtubeClientService: YouTubeClientService
    private(set) var configuration: GoogleOAuthClientConfiguration?

    init(youtubeClientService: YouTubeClientService) {
        self.youtubeClientService = youtubeClientService
        restorePersistedOAuthClient()
    }

    func load(from url: URL) -> GoogleOAuthClientConfiguration? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)
            let result = try youtubeClientService.loadOAuthClient(data: data)
            configuration = result.configuration
            status = "OAuth client loaded: \(redactedClientID(result.configuration.clientID)) (Keychain)"
            return result.configuration
        } catch {
            status = "OAuth client failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func restorePersistedOAuthClient() {
        do {
            guard let result = try youtubeClientService.restorePersistedOAuthClient() else {
                return
            }
            configuration = result.configuration
            status = "OAuth client loaded: \(redactedClientID(result.configuration.clientID))"
        } catch {
            status = "OAuth client restore failed: \(error.localizedDescription)"
        }
    }

    private func redactedClientID(_ clientID: String) -> String {
        guard clientID.count > 12 else { return "loaded" }
        return "\(clientID.prefix(8))...\(clientID.suffix(4))"
    }
}
