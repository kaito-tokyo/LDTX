// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI
import LDTXYouTubeAuth
import SwiftUI

struct LDTXApp: App {
    @StateObject private var oauthClientState: OAuthClientState
    @StateObject private var authState: YouTubeAuthState
    private let youtubeClientService: YouTubeClientService

    init() {
        let youtubeClientService = YouTubeClientService()
        self.youtubeClientService = youtubeClientService
        _oauthClientState = StateObject(
            wrappedValue: OAuthClientState(
                youtubeClientService: youtubeClientService,
                restoresPersistedOAuthClient: true
            )
        )
        _authState = StateObject(
            wrappedValue: YouTubeAuthState(youtubeClientService: youtubeClientService)
        )
    }

    var body: some Scene {
        Window("LDTX", id: "main") {
            WorkspaceContainer(
                oauthClientState: oauthClientState,
                authState: authState,
                youtubeClientService: youtubeClientService
            )
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            WorkspaceCommands()
        }
        Settings {
            YouTubeAccountSettingsView(
                oauthStatus: oauthClientState.status,
                authorizationStatus: authState.status,
                isImportingOAuthClient: Binding(
                    get: { oauthClientState.isImportingOAuthClient },
                    set: { oauthClientState.isImportingOAuthClient = $0 }
                ),
                canAuthorize: oauthClientState.configuration != nil && !authState.isAuthorizing,
                restoreAuthorization: {
                    authState.restore(for: oauthClientState.configuration)
                },
                authorizeYouTube: {
                    authState.authorize(configuration: oauthClientState.configuration)
                },
                loadOAuthClient: { url in
                    oauthClientState.load(from: url) != nil
                }
            )
        }
    }
}
