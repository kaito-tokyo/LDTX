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
    var outputCanvas: OutputCanvasModel
    @Binding var videoPTSMasterInputDeviceID: String?
    var videoPTSMasterInputDeviceOptions: [WorkspaceInputDeviceRecord]
    var outputDestination: AppOutputSettings
    var existingBroadcasts: [LiveBroadcastSummary]
    var isLoadingBroadcasts: Bool
    var supportsYouTube: Bool = true
    var refreshExistingBroadcasts: () -> Void
    var manageYouTubeBroadcasts: () -> Void
    var chooseOutputDirectory: () -> URL? = { nil }
    var applyOutputSettings: (AppOutputSettings) -> Void = { _ in }
    var captureFrame: () -> Void
    var openScreenshotsDirectory: () -> Void
    var verifyRecording: () -> Void
    var startOutputSession: () -> Void
    var pauseOutputSession: () -> Void
    var stopOutputSession: () -> Void
    var resetSession: () -> Void
    @State private var isShowingOutputSettings = false

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

                ProgramCanvasSettingsSection(
                    outputCanvas: outputCanvas,
                    windowState: windowState
                )
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
                Section("Output Settings") {
                    Button("Edit Output Settings…") {
                        isShowingOutputSettings = true
                    }
                    .disabled(windowState.isOperationLocked || windowState.outputSessionState == .running)
                    .accessibilityIdentifier("editOutputSettingsButton")
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
        .sheet(isPresented: $isShowingOutputSettings) {
            OutputSettingsSheet(
                outputDestination: outputDestination,
                windowState: windowState,
                existingBroadcasts: existingBroadcasts,
                isLoadingBroadcasts: isLoadingBroadcasts,
                supportsYouTube: supportsYouTube,
                refreshExistingBroadcasts: refreshExistingBroadcasts,
                manageYouTubeBroadcasts: manageYouTubeBroadcasts,
                chooseOutputDirectory: chooseOutputDirectory,
                apply: applyOutputSettings,
                dismiss: { isShowingOutputSettings = false }
            )
        }
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
}

private struct OutputSettingsSheet: View {
    @State private var draft: AppOutputSettings
    @State private var isShowingBroadcastChooser = false
    var windowState: WorkspaceWindowState
    var existingBroadcasts: [LiveBroadcastSummary]
    var isLoadingBroadcasts: Bool
    var supportsYouTube: Bool
    var refreshExistingBroadcasts: () -> Void
    var manageYouTubeBroadcasts: () -> Void
    var chooseOutputDirectory: () -> URL?
    var apply: (AppOutputSettings) -> Void
    var dismiss: () -> Void

    init(outputDestination: AppOutputSettings, windowState: WorkspaceWindowState, existingBroadcasts: [LiveBroadcastSummary], isLoadingBroadcasts: Bool, supportsYouTube: Bool, refreshExistingBroadcasts: @escaping () -> Void, manageYouTubeBroadcasts: @escaping () -> Void, chooseOutputDirectory: @escaping () -> URL?, apply: @escaping (AppOutputSettings) -> Void, dismiss: @escaping () -> Void) {
        _draft = State(initialValue: outputDestination)
        self.windowState = windowState
        self.existingBroadcasts = existingBroadcasts
        self.isLoadingBroadcasts = isLoadingBroadcasts
        self.supportsYouTube = supportsYouTube
        self.refreshExistingBroadcasts = refreshExistingBroadcasts
        self.manageYouTubeBroadcasts = manageYouTubeBroadcasts
        self.chooseOutputDirectory = chooseOutputDirectory
        self.apply = apply
        self.dismiss = dismiss
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Outputs") {
                    Toggle("Record", isOn: $draft.recording.isEnabled)
                    Toggle("YouTube", isOn: $draft.youtube.isEnabled).disabled(!supportsYouTube)
                }
                if draft.youtube.isEnabled {
                    Section("YouTube Broadcast") {
                        LabeledContent("Title", value: selectedBroadcast?.title ?? "Not selected")
                        Button(isLoadingBroadcasts ? "Loading" : "Select") {
                            isShowingBroadcastChooser = true
                            refreshExistingBroadcasts()
                        }
                        .disabled(!isBroadcastSelectionEnabled)
                        Button("Manage", action: manageYouTubeBroadcasts)
                    }
                }
                if draft.recording.isEnabled {
                    Section("Recording") {
                        LabeledContent("Output Folder", value: draft.recording.baseDirectoryURL?.path ?? "Default")
                        Button("Choose…") {
                            if let directory = chooseOutputDirectory() { draft.recording.baseDirectoryURL = directory }
                        }
                    }
                }
            }
            .navigationTitle("Output Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: dismiss) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply(draft); dismiss() }
                        .disabled(windowState.isOperationLocked || windowState.outputSessionState == .running)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 320)
        .sheet(isPresented: $isShowingBroadcastChooser) { broadcastChooser }
    }

    private var selectedBroadcast: LiveBroadcastSummary? {
        guard let id = draft.youtube.existingBroadcastID else { return nil }
        return existingBroadcasts.first { $0.id == id }
    }

    private var isBroadcastSelectionEnabled: Bool {
        draft.youtube.isEnabled
            && supportsYouTube
            && !isLoadingBroadcasts
            && !windowState.isOperationLocked
            && windowState.outputSessionState != .running
    }

    private var broadcastChooser: some View {
        NavigationStack {
            List(existingBroadcasts) { broadcast in
                Button(broadcast.title) {
                    draft.youtube.existingBroadcastID = broadcast.id
                    isShowingBroadcastChooser = false
                }
            }
            .navigationTitle("Select LiveBroadcast")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { isShowingBroadcastChooser = false } }
                ToolbarItem(placement: .primaryAction) { Button("Refresh", action: refreshExistingBroadcasts).disabled(isLoadingBroadcasts) }
            }
        }
        .frame(minWidth: 440, minHeight: 320)
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
