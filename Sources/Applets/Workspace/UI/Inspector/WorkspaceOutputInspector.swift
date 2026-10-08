// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppletSupport
import LDTXWorkspaceAppletInterface
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceOutputInspector: View {
  @Environment(\.documentReference) private var documentReference
  private var workspaceURL: URL? {
    guard let document = documentReference?.document else { return nil }
    return document.fileURL ?? storeService.localStateURL
  }
  @Bindable var storeService: WorkspaceStoreService
  @Bindable var appletData: WorkspaceAppletData
  @State private var isChoosingRecordingFolder = false
  @State private var isShowingStreamKeyManager = false
  @State private var streamKeyLoadError: String?

  var body: some View {
    Form {
      Section("Output") {
        LabeledContent(
          "Recording Folder", value: localState.recordingFolderPath ?? "Application default")
        Button("Choose Folder…") { isChoosingRecordingFolder = true }
          .disabled(workspaceURL == nil)
        if localState.recordingFolderPath != nil {
          Button("Use Application Default") {
            guard let workspaceURL else { return }
            appletData.updateState(for: workspaceURL) { $0.recordingFolderPath = nil }
          }
          .disabled(workspaceURL == nil)
        }
        Toggle("Enable Recording", isOn: $storeService.outputSettings.recordingEnabled)
        Toggle("Record Landscape", isOn: $storeService.outputSettings.recordingSettings.recordsLandscape)
        Toggle("Record Portrait", isOn: $storeService.outputSettings.recordingSettings.recordsPortrait)
        if storeService.outputSettings.recordingSettings.recordsLandscape
          || storeService.outputSettings.recordingSettings.recordsPortrait
        {
          RecordingCustomFieldsEditor(
            fields: storeService.outputSettings.recordingSettings.customFields,
            canEdit: !storeService.isOutputActive
          ) { fields in
            guard !storeService.isOutputActive else { return }
            storeService.outputSettings.recordingSettings.customFields = fields
          }
        }
        Toggle("Stream to YouTube", isOn: $storeService.outputSettings.youtubeEnabled)
        Picker(
          "YouTube Ingest",
          selection: $storeService.outputSettings.youtubeSettings.ingestMode
        ) {
          ForEach(
            [Ldtx_Workspace_V4_YouTubeIngestMode.landscapeRtmps, .portraitRtmps, .dualRtmps],
            id: \.rawValue
          ) { mode in
            Text(ingestModeLabel(mode)).tag(mode)
          }
        }
        if !isAvailableIngestMode(
          storeService.outputSettings.youtubeSettings.ingestMode)
        {
          Text("This YouTube ingest mode is not available yet.")
            .foregroundStyle(.secondary)
        }
        if usesLandscapeRTMPS {
          streamKeyPicker("Landscape Stream Key", keyPath: \.landscapeYouTubeLiveStreamID)
        }
        if usesPortraitRTMPS {
          streamKeyPicker("Portrait Stream Key", keyPath: \.portraitYouTubeLiveStreamID)
        }
        Button("Manage Stream Keys") { isShowingStreamKeyManager = true }
          .popover(isPresented: $isShowingStreamKeyManager) {
            WorkspaceV4StreamKeyManager(
              configurations: appletData.youtubeStreamKeyConfigurations,
              load: { try appletData.loadYouTubeStreamKeyConfigurations() },
              save: { try appletData.saveYouTubeStreamKeyConfigurations($0) },
              reportError: { storeService.reportError($0) }
            )
          }
      }
      .disabled(storeService.isOutputActive)
      .onAppear {
        do {
          _ = try appletData.loadYouTubeStreamKeyConfigurations()
          streamKeyLoadError = nil
        } catch {
          streamKeyLoadError = error.localizedDescription
          storeService.reportError(error)
        }
      }
    }
    .formStyle(.grouped)
    .fileImporter(
      isPresented: $isChoosingRecordingFolder,
      allowedContentTypes: [.folder]
    ) { result in
      do {
        let url = try result.get()
        guard !storeService.isOutputActive, let workspaceURL else { return }
        appletData.updateState(for: workspaceURL) {
          $0.recordingFolderPath = url.standardizedFileURL.path
        }
      } catch {
        storeService.reportError(error)
      }
    }
    .fileDialogDefaultDirectory(
      localState.recordingFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) })
    .fileDialogConfirmationLabel("Choose")
  }

  private var usesLandscapeRTMPS: Bool {
    switch storeService.outputSettings.youtubeSettings.ingestMode {
    case .landscapeRtmps, .dualRtmps: true
    default: false
    }
  }

  private var usesPortraitRTMPS: Bool {
    switch storeService.outputSettings.youtubeSettings.ingestMode {
    case .portraitRtmps, .dualRtmps: true
    default: false
    }
  }

  private func isAvailableIngestMode(_ mode: Ldtx_Workspace_V4_YouTubeIngestMode) -> Bool {
    switch mode {
    case .landscapeRtmps, .portraitRtmps, .dualRtmps: true
    default: false
    }
  }

  private var localState: WorkspaceLocalState {
    guard let workspaceURL else { return .init() }
    return appletData.state(for: workspaceURL)
  }

  private func streamKeyPicker(
    _ title: String, keyPath: WritableKeyPath<WorkspaceLocalState, String?>
  ) -> some View {
    WorkspaceSelectionField(
      title: title, current: localState[keyPath: keyPath],
      options: appletData.youtubeStreamKeyConfigurations.map { .init(id: $0.id, name: $0.name) },
      loadError: streamKeyLoadError, clearTitle: "Remove Assignment",
      isEditable: !storeService.isOutputActive && workspaceURL != nil,
      refresh: refreshStreamKeys,
      reportError: { storeService.reportError($0) },
      commit: { selected in
        guard !storeService.isOutputActive, let workspaceURL else {
          throw WorkspaceSelectionError(message: "Stop output before changing a stream key.")
        }
        if selected != nil { _ = try appletData.loadYouTubeStreamKeyConfigurations() }
        guard
          selected == nil
            || appletData.youtubeStreamKeyConfigurations.contains(where: { $0.id == selected })
        else { throw WorkspaceSelectionError(message: "The selected stream key no longer exists.") }
        appletData.updateState(for: workspaceURL) {
          $0[keyPath: keyPath] = selected
        }
      })
  }

  private func refreshStreamKeys() {
    do {
      _ = try appletData.loadYouTubeStreamKeyConfigurations()
      streamKeyLoadError = nil
    } catch {
      streamKeyLoadError = error.localizedDescription
      storeService.reportError(error)
    }
  }

  private func ingestModeLabel(_ mode: Ldtx_Workspace_V4_YouTubeIngestMode) -> String {
    switch mode {
    case .landscapeRtmps: "Landscape RTMPS"
    case .portraitRtmps: "Portrait RTMPS"
    case .dualRtmps: "Dual RTMPS"
    case .landscapeHls: "Landscape HLS"
    case .portraitHls: "Portrait HLS"
    case .landscapeDash: "Landscape DASH"
    case .portraitDash: "Portrait DASH"
    case .unspecified, .UNRECOGNIZED: "Unspecified"
    }
  }
}

#if DEBUG
  import Security

  @MainActor
  private enum WorkspaceOutputInspectorPreviewFixtures {
    static func makeStore(isOutputActive: Bool = false) -> WorkspaceStoreService {
      var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
      var outputSettings = Ldtx_Workspace_V4_WorkspaceOutputSettingsV4()
      outputSettings.recordingEnabled = true
      outputSettings.recordingSettings.recordsLandscape = true
      outputSettings.recordingSettings.recordsPortrait = true
      outputSettings.youtubeSettings.ingestMode = .dualRtmps
      outputSettings.recordingSettings.customFields = [
        "game": "Pokémon UNITE",
        "player": "Preview Player",
      ]
      return WorkspaceStoreService(
        definition: definition, preferences: .init(), isOutputActive: isOutputActive, outputSettings: outputSettings)
    }

    static func makeAppletData() -> WorkspaceAppletData {
      WorkspaceAppletData(
        userDefaults: UserDefaults(suiteName: "WorkspaceOutputInspectorPreview.\(UUID())")!,
        keychainClient: WorkspaceAppletKeychainClient(
          copyMatching: { _, _ in errSecItemNotFound },
          update: { _, _ in errSecSuccess },
          add: { _, _ in errSecSuccess }))
    }
  }

  #Preview("Output Settings") {
    @Previewable @State var storeService = WorkspaceOutputInspectorPreviewFixtures.makeStore()
    @Previewable @State var appletData = WorkspaceOutputInspectorPreviewFixtures.makeAppletData()

    WorkspaceOutputInspector(storeService: storeService, appletData: appletData)
      .frame(width: 480, height: 640)
  }

  #Preview("Output Active") {
    @Previewable @State var storeService = WorkspaceOutputInspectorPreviewFixtures.makeStore(
      isOutputActive: true)
    @Previewable @State var appletData = WorkspaceOutputInspectorPreviewFixtures.makeAppletData()

    WorkspaceOutputInspector(storeService: storeService, appletData: appletData)
      .frame(width: 480, height: 640)
  }
#endif
