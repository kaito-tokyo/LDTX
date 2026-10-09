// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXCapture
import LDTXProgram
import LDTXProgramRuntime
import LDTXTaskQueue
import LDTXWorkspaceAppletModel
import LDTXYouTube
import LDTXYouTubeRTMPS
import SwiftUI

struct OutputOrchestrationDetailPane: View {
  @Environment(\.scenePhase) private var scenePhase
  var selectedProgramName: String?
  var windowState: WorkspaceWindowState
  var isOutputSessionStartEnabled: Bool
  var outputSessionStartLabel: String
  var showsSessionControls: Bool = true
  var outputDestination: OutputDestination
  var selectedBroadcastID: String?
  var existingBroadcasts: [LiveBroadcastSummary]
  var selectedLandscapeLiveStreamID: String?
  var selectedPortraitLiveStreamID: String?
  var existingLiveStreams: [LiveStreamSummary]
  var isLoadingBroadcasts: Bool
  var supportsYouTube: Bool = true
  var refreshExistingBroadcasts: () -> Void
  var streamKeyConfigurations: [YouTubeRTMPSStreamKeyConfiguration] = []
  var loadStreamKeyConfigurations: () throws -> [YouTubeRTMPSStreamKeyConfiguration] = { [] }
  var saveStreamKeyConfigurations: ([YouTubeRTMPSStreamKeyConfiguration]) throws -> Void = { _ in }
  var importStreamKeyConfiguration: (String) async throws -> YouTubeRTMPSStreamKeyConfiguration = {
    _ in throw YouTubeRTMPSError.invalidDestination
  }
  var refreshExistingLiveStreams: () -> Void
  var manageYouTubeBroadcasts: () -> Void
  var chooseOutputDirectory: () -> URL? = { nil }
  var applyOutputSettings: (OutputDestination) -> Void = { _ in }
  var selectBroadcast: (String?) -> Void = { _ in }
  var selectLandscapeLiveStream: (String?) -> Void = { _ in }
  var selectPortraitLiveStream: (String?) -> Void = { _ in }
  var captureFrame: () -> Void
  var openScreenshotsDirectory: () -> Void
  var verifyRecording: () -> Void
  var startOutputSession: () -> Void
  var pauseOutputSession: () -> Void
  var stopOutputSession: () -> Void
  @State private var isShowingCustomFields = false
  @State private var isShowingStreamKeyManager = false
  @State private var loadedStreamKeyConfigurations: [YouTubeRTMPSStreamKeyConfiguration] = []
  @State private var didLoadStreamKeyConfigurations = false
  @State private var streamKeyLoadError: String?

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
          Toggle("Record Landscape", isOn: destinationBinding(\.recordsLandscape))
            .disabled(!canEditDestination)
          Toggle("Record Portrait", isOn: destinationBinding(\.recordsPortrait))
            .disabled(!canEditDestination)
          Toggle("YouTube", isOn: destinationBinding(\.streamsToYouTube))
            .disabled(!supportsYouTube || !canEditDestination)
        }
        if outputDestination.streamsToYouTube {
          Section("YouTube Ingest") {
            Picker("Protocol", selection: youtubeIngestModeBinding) {
              Text("DASH").tag(YouTubeIngestMode.dash)
              Text("YouTube RTMPS").tag(YouTubeIngestMode.dualRTMPS)
            }
            .disabled(!canEditDestination)
          }
          if outputDestination.youtubeIngestMode == .dash {
            Section("YouTube Broadcast") {
              Picker("Broadcast", selection: Binding(
                get: { selectedBroadcastID },
                set: { selectBroadcast($0) })
              ) {
                Text("Not selected").tag(String?.none)
                ForEach(existingBroadcasts) { broadcast in
                  Text(broadcast.title).tag(Optional(broadcast.id))
                }
                if let selectedBroadcastID,
                  !existingBroadcasts.contains(where: { $0.id == selectedBroadcastID })
                {
                  Text("Unavailable").tag(Optional(selectedBroadcastID))
                }
              }
              .pickerStyle(.menu)
              .disabled(!canEditDestination || isLoadingBroadcasts)
              .onAppear(perform: refreshExistingBroadcasts)
              Button(isLoadingBroadcasts ? "Loading" : "Refresh", action: refreshExistingBroadcasts)
                .disabled(isLoadingBroadcasts)
              Button("Manage", action: manageYouTubeBroadcasts)
            }
          } else {
            Section("YouTube Stream Keys") {
              liveStreamPicker(
                "Default", selection: selectedLandscapeLiveStreamID,
                excluding: selectedPortraitLiveStreamID, onSelect: selectLandscapeLiveStream)
              liveStreamPicker(
                "Vertical", selection: selectedPortraitLiveStreamID,
                excluding: selectedLandscapeLiveStreamID, onSelect: selectPortraitLiveStream)
              Button("Manage Stream Keys") {
                isShowingStreamKeyManager = true
              }
              .disabled(!canEditDestination || isLoadingBroadcasts)
              Button("Manage", action: manageYouTubeBroadcasts)
            }
          }
        }
        if outputDestination.recordsLocally {
          Section("Recording") {
            Toggle("Override Output Folder", isOn: outputFolderOverrideBinding)
              .disabled(!canEditDestination)
            if outputDestination.overridesOutputFolder {
              LabeledContent(
                "Output Folder", value: outputDestination.outputFolderPath ?? "Not selected")
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
            Button("Edit Custom Fields…") { isShowingCustomFields = true }
              .disabled(!canEditDestination)
              .sheet(isPresented: $isShowingCustomFields) {
                RecordingCustomFieldsSheet(
                  fields: Binding(
                    get: { outputDestination.recordingCustomFields },
                    set: { fields in
                      var destination = outputDestination
                      destination.recordingCustomFields = fields
                      applyOutputSettings(destination)
                    }),
                  canEdit: canEditDestination)
              }
          }
        }
        Section("Recording Integrity") {
          Button(action: verifyRecording) {
            Label("Verify Recording…", systemImage: "checkmark.circle")
          }
          .disabled(windowState.isOperationLocked)
          .accessibilityIdentifier("verifyRecordingButton")
        }
      }
      .formStyle(.grouped)
    }
    .onAppear {
      reloadStreamKeyConfigurations()
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      reloadStreamKeyConfigurations()
    }
    .sheet(isPresented: $isShowingStreamKeyManager) { streamKeyManager }
  }

  private func reloadStreamKeyConfigurations() {
    guard !didLoadStreamKeyConfigurations || scenePhase == .active else { return }
    didLoadStreamKeyConfigurations = true
    do {
      loadedStreamKeyConfigurations = try loadStreamKeyConfigurations()
      streamKeyLoadError = nil
    } catch {
      loadedStreamKeyConfigurations = []
      streamKeyLoadError = error.localizedDescription
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

  private func destinationBinding(_ keyPath: WritableKeyPath<OutputDestination, Bool>) -> Binding<
    Bool
  > {
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

  private var outputFolderOverrideBinding: Binding<Bool> {
    Binding(
      get: { outputDestination.overridesOutputFolder },
      set: { enabled in
        let selectedURL = enabled ? chooseOutputDirectory() : nil
        guard
          let destination = OutputFolderOverrideSelection.applying(
            enabled: enabled,
            selectedURL: selectedURL,
            to: outputDestination
          )
        else { return }
        applyOutputSettings(destination)
      }
    )
  }

  private var youtubeIngestModeBinding: Binding<YouTubeIngestMode> {
    Binding(
      get: { outputDestination.youtubeIngestMode },
      set: { mode in
        var destination = outputDestination
        destination.youtubeIngestMode = mode
        applyOutputSettings(destination)
      })
  }

  @ViewBuilder
  private func liveStreamPicker(
    _ title: String,
    selection: String?,
    excluding excludedID: String?,
    onSelect: @escaping (String?) -> Void
  ) -> some View {
    let excludedStreamKey = loadedStreamKeyConfigurations.first { $0.id == excludedID }?.streamKey
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let options = loadedStreamKeyConfigurations.filter {
      ($0.id != excludedID || $0.id == selection)
        && (excludedStreamKey == nil || $0.id == selection
          || $0.streamKey.trimmingCharacters(in: .whitespacesAndNewlines) != excludedStreamKey)
    }.map { WorkspaceSelectionOption(id: $0.id, name: $0.name) }
    VStack(alignment: .leading) {
      Picker(
        title,
        selection: Binding(
          get: { selection },
          set: { proposed in
            do {
              guard canEditDestination else {
                throw WorkspaceSelectionError(message: "Output settings are locked.")
              }
              guard let proposed else {
                onSelect(nil)
                return
              }
              let latest = try loadStreamKeyConfigurations()
              let excludedKey = latest.first { $0.id == excludedID }?.streamKey.trimmingCharacters(
                in: .whitespacesAndNewlines)
              guard
                latest.contains(where: {
                  $0.id == proposed && ($0.id != excludedID || $0.id == selection)
                    && (excludedKey == nil || $0.id == selection
                      || $0.streamKey.trimmingCharacters(in: .whitespacesAndNewlines) != excludedKey)
                })
              else {
                throw WorkspaceSelectionError(message: "The selected stream key is unavailable.")
              }
              onSelect(proposed)
            } catch { streamKeyLoadError = error.localizedDescription }
          })
      ) {
        Text("Unassigned").tag(String?.none)
        ForEach(options) { option in
          Text(option.name).tag(Optional(option.id))
        }
        if let selection, !options.contains(where: { $0.id == selection }) {
          Text(didLoadStreamKeyConfigurations ? "Unavailable" : "Checking…")
            .tag(Optional(selection))
        }
      }
      .pickerStyle(.menu)
      .disabled(!canEditDestination)
      .onAppear(perform: reloadStreamKeyConfigurations)
      if let streamKeyLoadError {
        Text(streamKeyLoadError).font(.caption).foregroundStyle(.red)
      }
    }
  }

  private var streamKeyManager: some View {
    YouTubeStreamKeyManager(
      configurations: loadedStreamKeyConfigurations,
      existingLiveStreams: existingLiveStreams,
      isLoading: isLoadingBroadcasts,
      refresh: refreshExistingLiveStreams,
      importConfiguration: importStreamKeyConfiguration,
      save: { configurations in
        try saveStreamKeyConfigurations(configurations)
        loadedStreamKeyConfigurations = configurations
      },
      load: loadStreamKeyConfigurations)
  }


}

private struct RecordingCustomFieldsSheet: View {
  private struct Row: Identifiable {
    let id = UUID()
    var key: String
    var value: String
  }

  @Environment(\.dismiss) private var dismiss
  @Binding var fields: [String: String]
  let canEdit: Bool
  @State private var rows: [Row]
  @FocusState private var focusedKey: UUID?

  init(fields: Binding<[String: String]>, canEdit: Bool) {
    self._fields = fields
    self.canEdit = canEdit
    _rows = State(
      initialValue: fields.wrappedValue.sorted { $0.key < $1.key }.map {
        Row(key: $0.key, value: $0.value)
      })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Custom Fields").font(.headline)
      Table($rows) {
        TableColumn("Key") { $row in
          TextField("Key", text: $row.key)
            .accessibilityLabel("Custom field key")
            .focused($focusedKey, equals: row.id)
        }
        TableColumn("Value") { $row in
          TextField("Value", text: $row.value)
            .accessibilityLabel("Custom field value")
        }
        TableColumn("") { $row in
          Button(role: .destructive) {
            rows.removeAll { $0.id == row.id }
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Remove custom field")
        }
        .width(28)
      }
      .disabled(!canEdit)
      Button {
        let row = Row(key: "", value: "")
        rows.append(row)
        focusedKey = row.id
      } label: {
        Label("Add Field", systemImage: "plus")
      }
      .disabled(!canEdit)
      if hasEmptyKey {
        Text("Keys must not be empty.").foregroundStyle(.red)
      } else if hasDuplicateKeys {
        Text("Keys must be unique.").foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Done") {
          guard canEdit, !hasEmptyKey, !hasDuplicateKeys else { return }
          fields = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.value) })
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canEdit || hasEmptyKey || hasDuplicateKeys)
      }
    }
    .padding()
    .frame(minWidth: 480, minHeight: 320)
  }

  private var hasEmptyKey: Bool { rows.contains { $0.key.isEmpty } }
  private var hasDuplicateKeys: Bool { Set(rows.map(\.key)).count != rows.count }
}

enum OutputFolderOverrideSelection {
  static func applying(
    enabled: Bool,
    selectedURL: URL?,
    to destination: OutputDestination
  ) -> OutputDestination? {
    var result = destination
    if enabled {
      guard let selectedURL else { return nil }
      result.overridesOutputFolder = true
      result.outputFolderPath = selectedURL.standardizedFileURL.path
    } else {
      result.overridesOutputFolder = false
      result.outputFolderPath = nil
    }
    return result
  }
}

struct CanvasDetailPane: View {
  var outputCanvas: OutputCanvasModel
  var videoBitRate: Int = 6_000_000
  var windowState: WorkspaceWindowState
  @Binding var videoPTSMasterInputDeviceID: String?
  var videoPTSMasterInputDeviceOptions: [ProgramInputDeviceRecord]

  var body: some View {
    @Bindable var outputCanvas = outputCanvas
    VStack(alignment: .leading, spacing: 0) {
      Text("Canvas")
        .font(.headline)
        .padding(.horizontal, 20)
        .padding(.top, 16)
      Form {
        Section("Canvas Preset") {
          Toggle(canvasPresetLabel, isOn: .constant(true))
            .toggleStyle(.button)
            .allowsHitTesting(false)
            .accessibilityIdentifier("canvasPresetSDR1080p60")
          LabeledContent(
            "Canvas Size",
            value: "\(outputCanvas.canvasSize.width) × \(outputCanvas.canvasSize.height)")
          LabeledContent(
            "Frame Rate", value: "\(outputCanvas.programDefinitionFrameRate) fps")
          LabeledContent("Video Bit Rate", value: formattedVideoBitRate)
            .accessibilityIdentifier("canvasVideoBitRatePicker")
          LabeledContent("Rate Control", value: "CBR")
          LabeledContent("Encoding", value: "H.264 High@L4.2, Rec.709 video range")
          LabeledContent("GOP", value: "2 seconds, no B-frames")
        }
        Section("Video Timing") {
          Picker("PTS Master", selection: $videoPTSMasterInputDeviceID) {
            Text("Host Clock").tag(String?.none)
            ForEach(videoPTSMasterInputDeviceOptions, id: \.id) { option in
              Text(option.name).tag(Optional(option.id))
            }
            if let selected = videoPTSMasterInputDeviceID,
              !videoPTSMasterInputDeviceOptions.contains(where: { $0.id == selected })
            {
              Text("Unavailable").tag(Optional(selected))
            }
          }
          .pickerStyle(.menu)
          .disabled(windowState.mode != .edit || windowState.isOperationLocked)
        }
      }
      .formStyle(.grouped)
    }
  }

  private var canvasPresetLabel: String {
    outputCanvas.canvasSize.height > outputCanvas.canvasSize.width
      ? "SDR Portrait 1080p60" : "SDR Landscape 1080p60"
  }

  private var formattedVideoBitRate: String {
    String(format: "%.1f Mbps", Double(videoBitRate) / 1_000_000)
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
