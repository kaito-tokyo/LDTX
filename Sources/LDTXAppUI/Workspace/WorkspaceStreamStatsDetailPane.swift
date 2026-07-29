// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import LDTXWorkspace

struct OutputOrchestrationDetailPane: View {
    var selectedProgramName: String?
    var windowState: WorkspaceWindowState
    var isOutputSessionStartEnabled: Bool
    var outputSessionStartLabel: String
    var showsSessionControls: Bool = true
    var outputDestination: OutputDestination
    var selectedBroadcastID: String?
    var existingBroadcasts: [LiveBroadcastSummary]
    var isLoadingBroadcasts: Bool
    var supportsYouTube: Bool = true
    var refreshExistingBroadcasts: () -> Void
    var manageYouTubeBroadcasts: () -> Void
    var chooseOutputDirectory: () -> URL? = { nil }
    var applyOutputSettings: (OutputDestination) -> Void = { _ in }
    var selectBroadcast: (String?) -> Void = { _ in }
    var captureFrame: () -> Void
    var openScreenshotsDirectory: () -> Void
    var verifyRecording: () -> Void
    var startOutputSession: () -> Void
    var pauseOutputSession: () -> Void
    var stopOutputSession: () -> Void
    var resetSession: () -> Void
    @State private var isShowingBroadcastChooser = false

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

                    if showsSessionControls {
                        HStack {
                            Button(action: captureFrame) {
                                Label("Capture Screenshot(s)", systemImage: "camera")
                            }
                            .disabled(!canCaptureOutputFrame)
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

                }

                Section("Destinations") {
                    Toggle("Record", isOn: destinationBinding(\.recordsLocally))
                    Toggle("YouTube", isOn: destinationBinding(\.streamsToYouTube))
                        .disabled(!supportsYouTube)
                }
                if outputDestination.streamsToYouTube {
                    Section("YouTube Broadcast") {
                        LabeledContent("Broadcast", value: selectedBroadcast?.title ?? "Not selected")
                        Button(isLoadingBroadcasts ? "Loading" : "Select Broadcast") {
                            refreshExistingBroadcasts()
                            isShowingBroadcastChooser = true
                        }
                        .disabled(!canEditDestination)
                        Button("Manage", action: manageYouTubeBroadcasts)
                    }
                }
                if outputDestination.recordsLocally {
                    Section("Recording") {
                        Toggle("Override Output Folder", isOn: destinationBinding(\.overridesOutputFolder))
                        if outputDestination.overridesOutputFolder {
                            LabeledContent("Output Folder", value: outputDestination.outputFolderPath ?? "Not selected")
                            Button("Choose Folder…") {
                                guard let url = chooseOutputDirectory() else { return }
                                var destination = outputDestination
                                destination.outputFolderPath = url.standardizedFileURL.path
                                applyOutputSettings(destination)
                            }
                            .disabled(!canEditDestination)
                        } else {
                            LabeledContent("Output Folder", value: "Application default")
                        }
                    }
                }
                Section("Recording Integrity") {
                    Button(action: verifyRecording) {
                        Label("Verify Recording…", systemImage: "checkmark.shield")
                    }
                    .disabled(windowState.isOperationLocked)
                    .accessibilityIdentifier("verifyRecordingShieldButton")
                }
            }
            .formStyle(.grouped)
        }
        .sheet(isPresented: $isShowingBroadcastChooser) { broadcastChooser }
    }

    private var canCaptureOutputFrame: Bool {
        isRecording && !windowState.isProgramRuntimeTransitioning
    }

    @ViewBuilder
    private var sessionButtons: some View {
        switch windowState.outputSessionState {
        case .idle, .readyToRestart:
            Button(outputSessionStartLabel, action: startOutputSession)
            .disabled(windowState.isOperationLocked || !isOutputSessionStartEnabled)
        case .running:
            Button("Pause", action: pauseOutputSession).disabled(windowState.isOperationLocked)
            Button("Stop", role: .destructive, action: stopOutputSession)
                .disabled(windowState.isOperationLocked)
        case .starting, .pausing, .stopping:
            ProgressView().controlSize(.small)
        }

        Button("Restart", action: resetSession)
            .disabled(windowState.isOperationLocked || isTransitioning)
    }

    private var sessionStatus: String {
        switch windowState.outputSessionState {
        case .idle: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .pausing: "Pausing"
        case .readyToRestart: "Paused"
        case .stopping: "Stopping"
        }
    }

    private var isTransitioning: Bool {
        switch windowState.outputSessionState {
        case .starting, .pausing, .stopping: true
        case .idle, .running, .readyToRestart: false
        }
    }

    private var isStreamingToYouTube: Bool {
        windowState.outputSessionState == .running
            && windowState.activeOutputMode?.streamsToYouTube == true
    }

    private var isRecording: Bool {
        windowState.outputSessionState == .running
            && windowState.activeOutputMode?.recordsLocally == true
            && !windowState.isRecordFinalizing
    }
    private var selectedBroadcast: LiveBroadcastSummary? {
        guard let selectedBroadcastID else { return nil }
        return existingBroadcasts.first { $0.id == selectedBroadcastID }
    }

    private var canEditDestination: Bool {
        !windowState.isOperationLocked && windowState.outputSessionState != .running
    }

    private func destinationBinding(_ keyPath: WritableKeyPath<OutputDestination, Bool>) -> Binding<Bool> {
        Binding(
            get: { outputDestination[keyPath: keyPath] },
            set: { value in
                var destination = outputDestination
                destination[keyPath: keyPath] = value
                if !destination.overridesOutputFolder { destination.outputFolderPath = nil }
                applyOutputSettings(destination)
            }
        )
    }

    private var broadcastChooser: some View {
        NavigationStack {
            List(existingBroadcasts) { broadcast in
                Button(broadcast.title) {
                    selectBroadcast(broadcast.id)
                    isShowingBroadcastChooser = false
                }
            }
            .navigationTitle("Select Live Broadcast")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { isShowingBroadcastChooser = false } }
                ToolbarItem(placement: .primaryAction) { Button("Refresh", action: refreshExistingBroadcasts).disabled(isLoadingBroadcasts) }
            }
        }
        .frame(minWidth: 440, minHeight: 320)
    }
}

struct CanvasDetailPane: View {
    var outputCanvas: OutputCanvasModel
    var windowState: WorkspaceWindowState
    @Binding var videoPTSMasterInputDeviceID: String?
    var videoPTSMasterInputDeviceOptions: [WorkspaceInputDeviceRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Canvas")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 16)
            Form {
                Section("Canvas Preset") {
                    LabeledContent("Preset", value: "SDR 1080p60")
                    LabeledContent("Canvas Size", value: "1920 × 1080")
                    LabeledContent("Frame Rate", value: "60 fps")
                }
                Section("Video Timing") {
                    Picker("PTS Master", selection: $videoPTSMasterInputDeviceID) {
                        Text("Host Clock").tag(String?.none)
                        ForEach(videoPTSMasterInputDeviceOptions) { inputDevice in
                            Text(inputDevice.name).tag(Optional(inputDevice.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(windowState.mode != .edit || windowState.isOperationLocked)
                    .accessibilityIdentifier("videoPTSMasterPicker")
                }
            }
            .formStyle(.grouped)
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
