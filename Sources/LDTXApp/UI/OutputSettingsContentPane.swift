// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXYouTube
import SwiftUI

struct OutputSettingsContentPane: View {
    @ObservedObject var oauthClientState: OAuthClientState
    @ObservedObject var authState: YouTubeAuthState
    var streamStatus: String
    var captureStatus: String
    @Binding var mainWindowState: MainWindowState
    @Binding var streamTitle: String
    @Binding var streamDescription: String
    @Binding var usesTemporaryStream: Bool
    var existingBroadcasts: [YouTubeLiveBroadcast]
    var isLoadingBroadcasts: Bool
    var isConnectingBroadcast: Bool
    var isStreamingToYouTube: Bool
    var isRecording: Bool
    var localOutputStore: LocalOutputStore
    var refreshExistingBroadcasts: () -> Void
    var manageYouTubeBroadcasts: () -> Void
    var chooseLocalOutputDirectory: () -> Void

    var body: some View {
        Form {
            ContentSettingsForm(
                oauthClientStatus: oauthClientState.status,
                authorizationStatus: authState.status,
                streamStatus: streamStatus,
                captureStatus: captureStatus,
                mainWindowState: $mainWindowState,
                streamTitle: $streamTitle,
                streamDescription: $streamDescription,
                usesTemporaryStream: $usesTemporaryStream,
                existingBroadcasts: existingBroadcasts,
                isLoadingBroadcasts: isLoadingBroadcasts,
                isConnectingBroadcast: isConnectingBroadcast,
                isStreamingToYouTube: isStreamingToYouTube,
                isRecording: isRecording,
                localOutputStore: localOutputStore,
                refreshExistingBroadcasts: refreshExistingBroadcasts,
                manageYouTubeBroadcasts: manageYouTubeBroadcasts,
                chooseLocalOutputDirectory: chooseLocalOutputDirectory
            )
        }
        .formStyle(.grouped)
    }
}
