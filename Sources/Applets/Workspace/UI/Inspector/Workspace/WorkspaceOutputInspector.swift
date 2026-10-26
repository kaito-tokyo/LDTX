// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceOutputInspector: View {
  @Binding var outputSettings: Ldtx_Workspace_V4_WorkspaceOutputSettingsV4
  let externalID: UUID
  let isOutputActive: Bool
  @Bindable var appletData: WorkspaceAppletData
  let reportError: (Error) -> Void
  @State private var isShowingStreamKeyManager = false
  @State private var isAddingCustomField = false
  @State private var streamKeyLoadError: String?
  @State private var newCustomFieldKey = ""
  @State private var landscapeKeyDraft: String?
  @State private var portraitKeyDraft: String?

  var body: some View {
    Form {
      Section("Recording") {
        LabeledContent("Recording Folder") {
          HStack {
            RecordingFolderPicker(path: $appletData.recordingFolderPaths[externalID])
            Button("Reset") {
              appletData.recordingFolderPaths[externalID] = nil
            }
          }
        }
        Toggle("Enable Recording", isOn: $outputSettings.recordingEnabled)
        Toggle("Record Landscape", isOn: $outputSettings.recordingSettings.recordsLandscape)
        Toggle("Record Portrait", isOn: $outputSettings.recordingSettings.recordsPortrait)
        Text("Custom Fields").font(.headline)
        ForEach(outputSettings.recordingSettings.customFields.keys.sorted(), id: \.self) { key in
          HStack {
            TextField(
              key,
              text:
                Binding($outputSettings.recordingSettings.customFields[key]) ?? .constant(""))
            Button("Remove", systemImage: "minus", role: .destructive) {
              outputSettings.recordingSettings.customFields.removeValue(forKey: key)
            }
            .labelStyle(.iconOnly)
          }
        }
        Button("Add Field…", systemImage: "plus") {
          newCustomFieldKey = ""
          isAddingCustomField = true
        }
      }
      Section("YouTube") {
        Toggle("Stream to YouTube", isOn: $outputSettings.youtubeEnabled)
        Picker(
          "YouTube Ingest",
          selection: $outputSettings.youtubeSettings.ingestMode
        ) {
          Text("Landscape RTMPS").tag(Ldtx_Workspace_V4_YouTubeIngestMode.landscapeRtmps)
          Text("Portrait RTMPS").tag(Ldtx_Workspace_V4_YouTubeIngestMode.portraitRtmps)
          Text("Dual RTMPS").tag(Ldtx_Workspace_V4_YouTubeIngestMode.dualRtmps)
        }
        streamKeyPicker(
          "Landscape Stream Key", selection: $appletData.landscapeYouTubeLiveStreamIDs[externalID],
          draft: $landscapeKeyDraft
        )
        .disabled(!outputSettings.youtubeSettings.ingestMode.usesLandscapeRTMPS)
        streamKeyPicker(
          "Portrait Stream Key", selection: $appletData.portraitYouTubeLiveStreamIDs[externalID],
          draft: $portraitKeyDraft
        )
        .disabled(!outputSettings.youtubeSettings.ingestMode.usesPortraitRTMPS)
        Button("Manage Stream Keys") { isShowingStreamKeyManager = true }
          .popover(isPresented: $isShowingStreamKeyManager) {
            WorkspaceV4StreamKeyManager(
              configurations: appletData.youtubeStreamKeyConfigurations,
              load: { try appletData.loadYouTubeStreamKeyConfigurations() },
              save: { try appletData.saveYouTubeStreamKeyConfigurations($0) },
              reportError: reportError
            )
          }
      }
    }
    .disabled(isOutputActive)
    .onAppear {
      do {
        _ = try appletData.loadYouTubeStreamKeyConfigurations()
        streamKeyLoadError = nil
      } catch {
        streamKeyLoadError = error.localizedDescription
        reportError(error)
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $isAddingCustomField) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Add Custom Field").font(.headline)
        TextField("Key", text: $newCustomFieldKey)
          .disabled(isOutputActive)
        HStack {
          Spacer()
          Button("Cancel", role: .cancel) { isAddingCustomField = false }
            .keyboardShortcut(.cancelAction)
          Button("Add") {
            guard !isOutputActive, !newCustomFieldKey.isEmpty,
              outputSettings.recordingSettings.customFields[newCustomFieldKey] == nil
            else { return }
            outputSettings.recordingSettings.customFields[newCustomFieldKey] = ""
            isAddingCustomField = false
          }
          .keyboardShortcut(.defaultAction)
          .disabled(
            isOutputActive || newCustomFieldKey.isEmpty
              || outputSettings.recordingSettings.customFields[newCustomFieldKey] != nil)
        }
      }
      .padding()
      .frame(width: 320)
    }
  }

  private func streamKeyPicker(
    _ title: String, selection: Binding<String?>, draft: Binding<String?>
  ) -> some View {
    VStack(alignment: .leading) {
      if let assigned = selection.wrappedValue {
        LabeledContent(
          "Assigned Key",
          value: appletData.youtubeStreamKeyConfigurations.first {
            $0.id == assigned
          }?.name ?? String(localized: "Unavailable"))
      }
      Picker(
        title,
        selection: Binding(
          get: { draft.wrappedValue },
          set: { selected in
            do {
              try selectStreamKey(selected, assignment: selection, draft: draft)
            } catch { reportError(error) }
          })
      ) {
        Text("Choose…").tag(String?.none).disabled(true)
        ForEach(appletData.youtubeStreamKeyConfigurations) { configuration in
          Text(configuration.name).tag(Optional(configuration.id))
        }
      }
      .pickerStyle(.menu)
      .disabled(isOutputActive)
      .onAppear(perform: refreshStreamKeys)
      .onChange(of: appletData.youtubeStreamKeyConfigurations.map(\.id)) { _, ids in
        draft.wrappedValue = WorkspaceSelectionRules.reconciled(
          draft.wrappedValue, availableIDs: ids)
      }
      if selection.wrappedValue != nil {
        Button("Remove Assignment") {
          do { try selectStreamKey(nil, assignment: selection, draft: draft) } catch {
            reportError(error)
          }
        }
        .disabled(isOutputActive)
      }
      if let streamKeyLoadError {
        Text(streamKeyLoadError).font(.caption).foregroundStyle(.red)
      }
    }
  }

  private func refreshStreamKeys() {
    do {
      _ = try appletData.loadYouTubeStreamKeyConfigurations()
      streamKeyLoadError = nil
    } catch {
      streamKeyLoadError = error.localizedDescription
      reportError(error)
    }
  }

  func selectStreamKey(_ selected: String?, assignment: Binding<String?>, draft: Binding<String?>)
    throws
  {
    guard !isOutputActive else {
      throw WorkspaceSelectionError(message: "Stop output before changing a stream key.")
    }
    if selected != nil { _ = try appletData.loadYouTubeStreamKeyConfigurations() }
    guard
      selected == nil
        || appletData.youtubeStreamKeyConfigurations.contains(where: { $0.id == selected })
    else {
      throw WorkspaceSelectionError(message: "The selected stream key no longer exists.")
    }
    assignment.wrappedValue = selected
    draft.wrappedValue = selected
  }

}

private struct RecordingFolderPicker: View {
  @Binding var path: String?
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.workspaceReportError) private var reportError
  @State private var isImporting = false

  var body: some View {
    HStack {
      Button {
        isImporting = true
      } label: {
        Text(path ?? String(localized: "(Default)"))
          .lineLimit(1).truncationMode(.middle)
      }
      .accessibilityLabel("Recording Folder")
      if path != nil {
        Button("Use Default", systemImage: "xmark.circle") { path = nil }
          .labelStyle(.iconOnly)
      }
    }
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder]) { result in
      guard isEnabled else { return }
      do { path = try result.get().standardizedFileURL.path } catch { reportError(error) }
    }
  }
}

#if DEBUG
  import Security

  @MainActor
  private enum WorkspaceOutputInspectorPreviewFixtures {
    static func makeStore(isOutputActive: Bool = false) -> WorkspaceDocument {
      let definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
      var outputSettings = Ldtx_Workspace_V4_WorkspaceOutputSettingsV4()
      outputSettings.recordingEnabled = true
      outputSettings.recordingSettings.recordsLandscape = true
      outputSettings.recordingSettings.recordsPortrait = true
      outputSettings.youtubeSettings.ingestMode = .dualRtmps
      outputSettings.recordingSettings.customFields = [
        "game": "Pokémon UNITE",
        "player": "Preview Player",
      ]
      return WorkspaceDocument(
        definition: definition, preferences: .init(), isOutputActive: isOutputActive,
        outputSettings: outputSettings)
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
    @Previewable @State var stateService = WorkspaceOutputInspectorPreviewFixtures.makeStore()
    @Previewable @State var appletData = WorkspaceOutputInspectorPreviewFixtures.makeAppletData()

    @Bindable var boundStore = stateService
    WorkspaceOutputInspector(
      outputSettings: boundStore.editingBinding(\.outputSettings, undoManager: nil),
      externalID: UUID(),
      isOutputActive: stateService.isOutputActive, appletData: appletData,
      reportError: { _ in }
    )
    .frame(width: 480, height: 640)
  }

  #Preview("Output Active") {
    @Previewable @State var stateService = WorkspaceOutputInspectorPreviewFixtures.makeStore(
      isOutputActive: true)
    @Previewable @State var appletData = WorkspaceOutputInspectorPreviewFixtures.makeAppletData()

    @Bindable var boundStore = stateService
    WorkspaceOutputInspector(
      outputSettings: boundStore.editingBinding(\.outputSettings, undoManager: nil),
      externalID: UUID(),
      isOutputActive: stateService.isOutputActive, appletData: appletData,
      reportError: { _ in }
    )
    .frame(width: 480, height: 640)
  }
#endif
