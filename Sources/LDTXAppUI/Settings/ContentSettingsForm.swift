// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXYouTube
import SwiftUI

enum ContentSettingsPlacement {
    case content
    case detail
    case modal
}

struct ContentSettingsForm: View {
    @AppStorage(OutputSettingsStorageKey.broadcastSourceMode)
    private var storedBroadcastSourceMode = BroadcastSourceMode.createNew.rawValue
    @AppStorage(OutputSettingsStorageKey.resolution)
    private var storedResolution = YouTubeLiveStreamResolution.p1080.rawValue
    @AppStorage(OutputSettingsStorageKey.frameRate)
    private var storedFrameRate = YouTubeLiveStreamFrameRate.fps60.rawValue
    @AppStorage(OutputSettingsStorageKey.privacyStatus)
    private var storedPrivacyStatus = YouTubeLiveBroadcastPrivacyStatus.private.rawValue
    @AppStorage(OutputSettingsStorageKey.latencyPreference)
    private var storedLatencyPreference = YouTubeLiveBroadcastLatencyPreference.low.rawValue
    @AppStorage(OutputSettingsStorageKey.existingBroadcastID)
    private var storedExistingBroadcastID = ""
    @AppStorage(OutputSettingsStorageKey.captureOutputMode)
    private var storedCaptureOutputMode = CaptureOutputMode.youtube.rawValue

    var oauthClientStatus: String
    var authorizationStatus: String
    var streamStatus: String
    var captureStatus: String
    @Bindable var outputDestination: OutputDestinationModel
    var existingBroadcasts: [YouTubeLiveBroadcast]
    var isLoadingBroadcasts: Bool
    var isConnectingBroadcast: Bool
    var isStreamingToYouTube: Bool
    var isRecording: Bool
    var localOutputStatus: String
    var refreshExistingBroadcasts: () -> Void
    var manageYouTubeBroadcasts: () -> Void
    var chooseLocalOutputDirectory: () -> Void
    var placement: ContentSettingsPlacement = .content
    @State private var isShowingBroadcastChooser = false

    var body: some View {
        Group {
            switch placement {
            case .content:
                outputSection
            case .detail:
                outputDetailSections
            case .modal:
                outputSection
                outputDetailSections
            }
        }
        .onAppear {
            restoreStoredSelections()
        }
        .onChange(of: outputDestination.selectedBroadcastSourceMode) { _, mode in
            storedBroadcastSourceMode = mode.rawValue
        }
        .onChange(of: outputDestination.selectedResolution) { _, resolution in
            storedResolution = resolution.rawValue
        }
        .onChange(of: outputDestination.selectedFrameRate) { _, frameRate in
            storedFrameRate = frameRate.rawValue
        }
        .onChange(of: outputDestination.selectedPrivacyStatus) { _, status in
            storedPrivacyStatus = status.rawValue
        }
        .onChange(of: outputDestination.selectedLatencyPreference) { _, latency in
            storedLatencyPreference = latency.rawValue
        }
        .onChange(of: outputDestination.selectedExistingBroadcastID) { _, broadcastID in
            storedExistingBroadcastID = broadcastID ?? ""
        }
        .onChange(of: outputDestination.selectedCaptureOutputMode) { _, mode in
            storedCaptureOutputMode = mode.rawValue
        }
        .sheet(isPresented: $isShowingBroadcastChooser) {
            broadcastChooser
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent("OAuth") {
                Text(oauthClientStatus)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Authorization") {
                Text(authorizationStatus)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("YouTube") {
                Text(streamStatus)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var youtubeBroadcastSection: some View {
        Section("YouTube Broadcast") {
            TextField("Title", text: $outputDestination.streamTitle)
            TextField("Description", text: $outputDestination.streamDescription, axis: .vertical)
                .lineLimit(2...4)

            Picker("Resolution", selection: $outputDestination.selectedResolution) {
                ForEach(YouTubeLiveStreamResolution.allCases, id: \.self) { resolution in
                    Text(resolution.rawValue).tag(resolution)
                }
            }

            Picker("Frame Rate", selection: $outputDestination.selectedFrameRate) {
                ForEach(YouTubeLiveStreamFrameRate.allCases, id: \.self) { frameRate in
                    Text(frameRate.rawValue).tag(frameRate)
                }
            }

            Picker("Privacy", selection: $outputDestination.selectedPrivacyStatus) {
                ForEach(YouTubeLiveBroadcastPrivacyStatus.allCases, id: \.self) { status in
                    switch status {
                    case .private:
                        Text("Private").tag(status)
                    case .unlisted:
                        Text("Unlisted").tag(status)
                    case .public:
                        Text("Public").tag(status)
                    }
                }
            }

            Picker("Latency", selection: $outputDestination.selectedLatencyPreference) {
                ForEach(YouTubeLiveBroadcastLatencyPreference.allCases, id: \.self) { latency in
                    switch latency {
                    case .normal:
                        Text("Normal").tag(latency)
                    case .low:
                        Text("Low").tag(latency)
                    case .ultraLow:
                        Text("Ultra Low").tag(latency)
                    }
                }
            }

            Toggle("Temporary LiveStream", isOn: $outputDestination.usesTemporaryStream)
                .disabled(true)

            if let selectedBroadcast {
                LabeledContent("Selected") {
                    Text(existingBroadcastLabel(selectedBroadcast))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            HStack {
                Button {
                    manageYouTubeBroadcasts()
                } label: {
                    Label("Manage", systemImage: "arrow.up.right.square")
                }

                Button {
                    refreshExistingBroadcasts()
                    isShowingBroadcastChooser = true
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                .disabled(
                    isLoadingBroadcasts ||
                        isConnectingBroadcast ||
                        isStreamingToYouTube ||
                        isRecording ||
                        !outputDestination.selectedCaptureOutputMode.streamsToYouTube
                )

                if isLoadingBroadcasts || isConnectingBroadcast {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var outputDetailSections: some View {
        switch outputDestination.selectedCaptureOutputMode {
        case .youtube:
            connectionSection
            youtubeBroadcastSection
        case .record:
            recordingSection
        case .youtubeAndRecord:
            connectionSection
            youtubeBroadcastSection
            recordingSection
        }
    }

    private var broadcastChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select YouTube Broadcast")
                .font(.headline)

            if isLoadingBroadcasts {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading broadcasts")
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 420, alignment: .leading)
            } else if existingBroadcasts.isEmpty {
                Text("No active or upcoming broadcasts")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 420, alignment: .leading)
            } else {
                List(existingBroadcasts) { broadcast in
                    Button {
                        outputDestination.selectedBroadcastSourceMode = .useExisting
                        outputDestination.selectedExistingBroadcastID = broadcast.id
                        isShowingBroadcastChooser = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(broadcast.snippet?.title ?? "Untitled")
                            if let scheduledStartTime = broadcast.snippet?.scheduledStartTime {
                                Text(scheduledStartTime)
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(minWidth: 420, minHeight: 220)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isShowingBroadcastChooser = false
                }
            }
        }
        .padding(20)
    }

    private var outputSection: some View {
        Section("Output") {
            Picker("Output", selection: $outputDestination.selectedCaptureOutputMode) {
                ForEach(CaptureOutputMode.allCases) { mode in
                    switch mode {
                    case .youtube:
                        Text("YouTube").tag(mode)
                    case .record:
                        Text("Record").tag(mode)
                    case .youtubeAndRecord:
                        Text("YouTube+Record").tag(mode)
                    }
                }
            }
            .disabled(isCaptureOutputRunning)

            LabeledContent("Status") {
                Text(captureStatus)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recordingSection: some View {
        Section("Recording") {
            HStack {
                LabeledContent("Output Folder") {
                    Text(localOutputStatus)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Button {
                    chooseLocalOutputDirectory()
                } label: {
                    Label("Choose", systemImage: "folder")
                }
            }
        }
    }

    private func existingBroadcastLabel(_ broadcast: YouTubeLiveBroadcast) -> String {
        let title = broadcast.snippet?.title ?? broadcast.id ?? "Untitled"
        guard let scheduledStartTime = broadcast.snippet?.scheduledStartTime else {
            return title
        }
        return "\(title) - \(scheduledStartTime)"
    }

    private var selectedBroadcast: YouTubeLiveBroadcast? {
        guard let selectedExistingBroadcastID = outputDestination.selectedExistingBroadcastID else {
            return nil
        }
        return existingBroadcasts.first { $0.id == selectedExistingBroadcastID }
    }

    private var isCaptureOutputRunning: Bool {
        isStreamingToYouTube || isRecording
    }

    private func restoreStoredSelections() {
        if let mode = BroadcastSourceMode(rawValue: storedBroadcastSourceMode) {
            outputDestination.selectedBroadcastSourceMode = mode
        }
        if let resolution = YouTubeLiveStreamResolution(rawValue: storedResolution) {
            outputDestination.selectedResolution = resolution
        }
        if let frameRate = YouTubeLiveStreamFrameRate(rawValue: storedFrameRate) {
            outputDestination.selectedFrameRate = frameRate
        }
        if let status = YouTubeLiveBroadcastPrivacyStatus(rawValue: storedPrivacyStatus) {
            outputDestination.selectedPrivacyStatus = status
        }
        if let latency = YouTubeLiveBroadcastLatencyPreference(rawValue: storedLatencyPreference) {
            outputDestination.selectedLatencyPreference = latency
        }
        outputDestination.selectedExistingBroadcastID =
            storedExistingBroadcastID.isEmpty ? nil : storedExistingBroadcastID
        if let mode = CaptureOutputMode(rawValue: storedCaptureOutputMode) {
            outputDestination.selectedCaptureOutputMode = mode
        }
    }
}

#if DEBUG
#Preview("Content Settings Form") {
    ContentSettingsFormPreviewHost()
        .frame(width: 560, height: 760)
}

private struct ContentSettingsFormPreviewHost: View {
    @State private var outputDestination = LDTXAppUIPreviewFixtures.makeOutputDestinationModel()

    var body: some View {
        Form {
            ContentSettingsForm(
                oauthClientStatus: LDTXAppUIPreviewFixtures.oauthClientStatus,
                authorizationStatus: LDTXAppUIPreviewFixtures.authorizationStatus,
                streamStatus: LDTXAppUIPreviewFixtures.streamStatus,
                captureStatus: LDTXAppUIPreviewFixtures.captureStatus,
                outputDestination: outputDestination,
                existingBroadcasts: LDTXAppUIPreviewFixtures.existingBroadcasts,
                isLoadingBroadcasts: false,
                isConnectingBroadcast: false,
                isStreamingToYouTube: false,
                isRecording: false,
                localOutputStatus: LDTXAppUIPreviewFixtures.localOutputStatus,
                refreshExistingBroadcasts: {},
                manageYouTubeBroadcasts: {},
                chooseLocalOutputDirectory: {},
                placement: .modal
            )
        }
        .formStyle(.grouped)
    }
}
#endif
