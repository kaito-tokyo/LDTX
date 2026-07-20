// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct WorkspaceStreamStatsDetailPane: View {
    var outputCanvas: OutputCanvasModel
    var outputDestination: OutputDestinationModel
    var existingBroadcasts: [LiveBroadcastSummary]
    var isLoadingBroadcasts: Bool
    var isConnectingBroadcast: Bool
    var isStreamingToYouTube: Bool
    var isRecording: Bool
    var canSelectYouTubeBroadcast: Bool
    var supportsYouTube: Bool = true
    var canEditOutputSettings: Bool
    var localOutputStatus: String
    var refreshExistingBroadcasts: () -> Void
    var manageYouTubeBroadcasts: () -> Void
    var chooseLocalOutputDirectory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Output Destination settings")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            Form {
                ProgramCanvasSettingsSection(
                    outputCanvas: outputCanvas
                )

                ContentSettingsForm(
                    outputDestination: outputDestination,
                    existingBroadcasts: existingBroadcasts,
                    isLoadingBroadcasts: isLoadingBroadcasts,
                    isConnectingBroadcast: isConnectingBroadcast,
                    isStreamingToYouTube: isStreamingToYouTube,
                    isRecording: isRecording,
                    canSelectYouTubeBroadcast: canSelectYouTubeBroadcast,
                    supportsYouTube: supportsYouTube,
                    localOutputStatus: localOutputStatus,
                    refreshExistingBroadcasts: refreshExistingBroadcasts,
                    manageYouTubeBroadcasts: manageYouTubeBroadcasts,
                    chooseLocalOutputDirectory: chooseLocalOutputDirectory,
                    placement: .modal
                )
            }
            .formStyle(.grouped)
            .disabled(!canEditOutputSettings)
        }
    }
}
