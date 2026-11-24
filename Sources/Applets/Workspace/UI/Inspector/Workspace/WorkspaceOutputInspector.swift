// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import LDTXWorkspaceAppletModel
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceOutputInspector: View {
  @Binding var outputSettings: Ldtx_Workspace_V4_WorkspaceOutputSettingsV4
  let externalID: UUID
  let isOutputActive: Bool
  @Bindable var appletData: WorkspaceAppletData
  let reportError: (Error) -> Void
  @Environment(\.openSettings) private var openSettings
  @State private var isAddingCustomField = false
  @State private var streamKeyLoadError: String?
  @State private var newCustomFieldKey = ""

  private var recording: Binding<Ldtx_Workspace_V4_RecordingOutputSettings> {
    $outputSettings.recordingSettings.defaulting(to: .init())
  }

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
        Toggle("Enable Recording", isOn: $outputSettings.recordingEnabled.defaulting(to: false))
        Toggle("Record Landscape", isOn: recording.recordsLandscape.defaulting(to: false))
        Toggle("Record Portrait", isOn: recording.recordsPortrait.defaulting(to: false))
        Text("Custom Fields").font(.headline)
        ForEach(recording.wrappedValue.customFields.keys.sorted(), id: \.self) { key in
          HStack {
            TextField(
              key,
              text:
                Binding(recording.customFields[key]) ?? .constant(""))
            Button("Remove", systemImage: "minus", role: .destructive) {
              recording.wrappedValue.customFields.removeValue(forKey: key)
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
        Toggle("Stream to YouTube", isOn: $outputSettings.youtubeEnabled.defaulting(to: false))
        Picker(
          "YouTube Ingest",
          selection: $outputSettings.youtubeSettings.defaulting(to: .init()).ingestMode.defaulting(
            to: .landscapeRtmps)
        ) {
          Text("Landscape RTMPS").tag(Ldtx_Workspace_V4_YouTubeIngestMode.landscapeRtmps)
          Text("Portrait RTMPS").tag(Ldtx_Workspace_V4_YouTubeIngestMode.portraitRtmps)
          Text("Dual RTMPS").tag(Ldtx_Workspace_V4_YouTubeIngestMode.dualRtmps)
        }
        streamKeyPicker(
          "Landscape Stream Key", assignment: $appletData.landscapeYouTubeLiveStreamIDs[externalID]
        )
        .disabled(!(outputSettings.youtubeSettings?.ingestMode ?? .unspecified).usesLandscapeRTMPS)
        streamKeyPicker(
          "Portrait Stream Key", assignment: $appletData.portraitYouTubeLiveStreamIDs[externalID]
        )
        .disabled(!(outputSettings.youtubeSettings?.ingestMode ?? .unspecified).usesPortraitRTMPS)
        if let streamKeyLoadError {
          Text(streamKeyLoadError).font(.caption).foregroundStyle(.red)
        } else if appletData.youtubeStreamKeyConfigurations.isEmpty {
          Text("No stream keys. Add stream keys in Settings.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Button("Edit Stream Keys in Settings…", action: openStreamKeySettings)
      }
    }
    .disabled(isOutputActive)
    .onAppear(perform: refreshStreamKeys)
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
              recording.wrappedValue.customFields[newCustomFieldKey] == nil
            else { return }
            recording.wrappedValue.customFields[newCustomFieldKey] = ""
            isAddingCustomField = false
          }
          .keyboardShortcut(.defaultAction)
          .disabled(
            isOutputActive || newCustomFieldKey.isEmpty
              || recording.wrappedValue.customFields[newCustomFieldKey] != nil)
        }
      }
      .padding()
      .frame(width: 320)
    }
  }

  /// A plain dropdown bound to the saved assignment. A saved ID without a configuration is
  /// listed as an unavailable, unselectable item, so it stays visible and is not rewritten
  /// until the user picks another stream key or None.
  private func streamKeyPicker(_ title: String, assignment: Binding<String?>) -> some View {
    Picker(
      title,
      selection: Binding(
        get: { assignment.wrappedValue },
        set: { selected in
          do { try selectStreamKey(selected, assignment: assignment) } catch { reportError(error) }
        })
    ) {
      Text("None").tag(String?.none)
      ForEach(appletData.youtubeStreamKeyConfigurations) { configuration in
        Text(configuration.name).tag(Optional(configuration.id))
      }
      if let assigned = assignment.wrappedValue,
        !appletData.youtubeStreamKeyConfigurations.contains(where: { $0.id == assigned })
      {
        Text("Unavailable").tag(Optional(assigned)).disabled(true)
      }
    }
    .pickerStyle(.menu)
  }

  private func openStreamKeySettings() {
    UserDefaults.standard.set(
      ApplicationSettingsTab.streamKeys.rawValue, forKey: ApplicationSettingsTab.defaultsKey)
    openSettings()
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

  func selectStreamKey(_ selected: String?, assignment: Binding<String?>) throws {
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
      outputSettings.recordingSettings = .with {
        $0.recordsLandscape = true
        $0.recordsPortrait = true
        $0.customFields = ["game": "Pokémon UNITE", "player": "Preview Player"]
      }
      outputSettings.youtubeSettings = .with { $0.ingestMode = .dualRtmps }
      return WorkspaceDocument(
        definition: definition, preferences: .init(), isOutputActive: isOutputActive,
        outputSettings: outputSettings)
    }

    static func makeAppletData() -> WorkspaceAppletData {
      WorkspaceAppletData(
        userDefaults: UserDefaults(suiteName: "WorkspaceOutputInspectorPreview.\(UUID())")!,
        streamKeyKeychainOperations: DataProtectionKeychainItem.Operations(
          copyMatching: { _, _ in errSecItemNotFound },
          add: { _, _ in errSecSuccess },
          update: { _, _ in errSecItemNotFound },
          delete: { _ in errSecItemNotFound }))
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
