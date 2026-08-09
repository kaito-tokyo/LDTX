// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace
import SwiftUI

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
            .disabled(!canEditDestination)
          Toggle("YouTube", isOn: destinationBinding(\.streamsToYouTube))
            .disabled(!supportsYouTube || !canEditDestination)
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
            RecordingCustomFieldsEditor(
              fields: outputDestination.recordingCustomFields,
              canEdit: canEditDestination
            ) { fields in
              var destination = outputDestination
              destination.recordingCustomFields = fields
              applyOutputSettings(destination)
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
        guard let destination = OutputFolderOverrideSelection.applying(
          enabled: enabled,
          selectedURL: selectedURL,
          to: outputDestination
        ) else { return }
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
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { isShowingBroadcastChooser = false }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Refresh", action: refreshExistingBroadcasts).disabled(isLoadingBroadcasts)
        }
      }
    }
    .frame(minWidth: 440, minHeight: 320)
  }
}

private struct RecordingCustomFieldsEditor: View {
  private enum Field: Hashable {
    case key(UUID)
    case value(UUID)
  }

  private struct Row: Identifiable, Equatable {
    let id: UUID
    var key: String
    var value: String
  }

  let fields: [String: String]
  let canEdit: Bool
  let apply: ([String: String]) -> Void
  @State private var rows: [Row]
  @FocusState private var focusedField: Field?

  init(
    fields: [String: String],
    canEdit: Bool,
    apply: @escaping ([String: String]) -> Void
  ) {
    self.fields = fields
    self.canEdit = canEdit
    self.apply = apply
    _rows = State(initialValue: Self.rows(for: fields))
  }

  var body: some View {
    Divider()
    Text("Custom Fields").font(.headline)
    ForEach($rows) { $row in
      HStack {
        TextField("Key", text: $row.key)
          .accessibilityLabel("Custom field key")
          .focused($focusedField, equals: .key(row.id))
          .onSubmit(saveIfValid)
        TextField("Value", text: $row.value)
          .accessibilityLabel("Custom field value")
          .focused($focusedField, equals: .value(row.id))
          .onSubmit(saveIfValid)
        Button(role: .destructive) {
          rows.removeAll { $0.id == row.id }
          saveIfValid()
        } label: {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Remove custom field")
      }
      .disabled(!canEdit)
    }
    if let validationMessage {
      Text(validationMessage)
        .font(.caption)
        .foregroundStyle(.red)
    }
    Button {
      let id = UUID()
      rows.append(Row(id: id, key: "", value: ""))
      focusedField = .key(id)
    } label: {
      Label("Add Field", systemImage: "plus")
    }
    .disabled(!canEdit || validationMessage != nil)
    .onChange(of: focusedField) { oldField, newField in
      if oldField != nil, oldField != newField { saveIfValid() }
    }
    .onChange(of: fields) { _, newFields in
      guard dictionaryValue != newFields else { return }
      rows = Self.rows(for: newFields)
    }
  }

  private var validationMessage: String? {
    if rows.contains(where: { $0.key.isEmpty }) { return "Keys must not be empty." }
    let keys = rows.map(\.key)
    if Set(keys).count != keys.count { return "Keys must be unique." }
    return nil
  }

  private var dictionaryValue: [String: String] {
    rows.reduce(into: [:]) { $0[$1.key] = $1.value }
  }

  private func saveIfValid() {
    guard validationMessage == nil else { return }
    let value = dictionaryValue
    guard value != fields else { return }
    apply(value)
  }

  private static func rows(for fields: [String: String]) -> [Row] {
    fields.keys.sorted().map { Row(id: UUID(), key: $0, value: fields[$0] ?? "") }
  }
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
  var windowState: WorkspaceWindowState
  @Binding var videoPTSMasterInputDeviceID: String?
  var videoPTSMasterInputDeviceOptions: [WorkspaceInputDeviceRecord]

  var body: some View {
    @Bindable var outputCanvas = outputCanvas
    VStack(alignment: .leading, spacing: 0) {
      Text("Canvas")
        .font(.headline)
        .padding(.horizontal, 20)
        .padding(.top, 16)
      Form {
        Section("Canvas Preset") {
          Toggle("SDR 1080p60", isOn: .constant(true))
            .toggleStyle(.button)
            .allowsHitTesting(false)
            .accessibilityIdentifier("canvasPresetSDR1080p60")
          LabeledContent("Canvas Size", value: "1920 × 1080")
          LabeledContent("Frame Rate", value: "60 fps")
          LabeledContent("Video Bit Rate", value: "6.0 Mbps")
          .accessibilityIdentifier("canvasVideoBitRatePicker")
          LabeledContent("Rate Control", value: "CBR")
          LabeledContent("Encoding", value: "H.264 High@L4.2, Rec.709 video range")
          LabeledContent("GOP", value: "2 seconds, no B-frames")
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
