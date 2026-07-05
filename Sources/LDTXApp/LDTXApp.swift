// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXYouTube
import SwiftUI

@main
struct LDTXApp: App {
    @StateObject private var oauthClientState: OAuthClientState
    @StateObject private var authState: YouTubeAuthState
    private let youtubeClientService: YouTubeClientService

    init() {
        let youtubeClientService = YouTubeClientService(
            authorizationStore: YouTubeAuthorizationStore(),
            oauthClientStore: OAuthClientConfigurationStore()
        )
        self.youtubeClientService = youtubeClientService
        _oauthClientState = StateObject(
            wrappedValue: OAuthClientState(youtubeClientService: youtubeClientService)
        )
        _authState = StateObject(
            wrappedValue: YouTubeAuthState(youtubeClientService: youtubeClientService)
        )
    }

    var body: some Scene {
        Window("LDTX", id: "main") {
            WorkspaceView(
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
                oauthClientState: oauthClientState,
                authState: authState
            )
        }
    }
}
