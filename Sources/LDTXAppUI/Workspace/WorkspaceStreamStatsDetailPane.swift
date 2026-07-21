// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct OutputOrchestrationDetailPane: View {
    var selectedProgramName: String?
    var outputSessionControlState: OutputSessionControlState
    var isOutputOperationLocked: Bool
    var isOutputSessionStartEnabled: Bool
    var outputSessionStartLabel: String
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
    var captureFrame: () -> Void
    var openScreenshotsDirectory: () -> Void
    var startOutputSession: () -> Void
    var pauseOutputSession: () -> Void
    var stopOutputSession: () -> Void
    var resetSession: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Output")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            Form {
                Section("Session") {
                    LabeledContent("Status", value: sessionStatus)
                    LabeledContent("Program", value: selectedProgramName ?? "No Program")
                    if supportsYouTube {
                        LabeledContent("YouTube", value: isStreamingToYouTube ? "Streaming" : "Stopped")
                    }
                    LabeledContent("Recording", value: isRecording ? "Recording" : "Stopped")

                    HStack {
                        Button(action: captureFrame) {
                            Label("Capture Screenshot(s)", systemImage: "camera")
                        }
                        .disabled(!isRecording)
                        .accessibilityIdentifier("captureOutputFrameButton")

                        Button(action: openScreenshotsDirectory) {
                            Label("Open Screenshots Folder", systemImage: "folder")
                        }
                        .disabled(!isRecording)
                        .accessibilityIdentifier("openScreenshotsDirectoryButton")

                        Spacer()
                        sessionButtons
                    }

                }

                Group {
                    ProgramCanvasSettingsSection(outputCanvas: outputCanvas)
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
                .disabled(!canEditOutputSettings)
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private var sessionButtons: some View {
        switch outputSessionControlState {
        case .idle, .readyToRestart:
            Button(outputSessionStartLabel, action: startOutputSession)
                .disabled(isOutputOperationLocked || !isOutputSessionStartEnabled)
        case .running:
            Button("Pause", action: pauseOutputSession).disabled(isOutputOperationLocked)
            Button("Stop", role: .destructive, action: stopOutputSession)
                .disabled(isOutputOperationLocked)
        case .starting, .pausing, .stopping:
            ProgressView().controlSize(.small)
        }

        Button("Restart", action: resetSession)
            .disabled(isOutputOperationLocked || isTransitioning)
    }

    private var sessionStatus: String {
        switch outputSessionControlState {
        case .idle: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .pausing: "Pausing"
        case .readyToRestart: "Paused"
        case .stopping: "Stopping"
        }
    }

    private var isTransitioning: Bool {
        switch outputSessionControlState {
        case .starting, .pausing, .stopping: true
        case .idle, .running, .readyToRestart: false
        }
    }
}

public struct OutputFrameCaptureFeedback: Equatable, Sendable {
    public let id: UUID
    public var message: String
    public var isError: Bool

    public init(message: String, isError: Bool) {
        id = UUID()
        self.message = message
        self.isError = isError
    }
}
