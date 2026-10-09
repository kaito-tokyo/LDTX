// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXBackgroundSegmentation
import LDTXCapture
import LDTXProgramRuntime
import LDTXProtos
import LDTXTaskQueue
import LDTXYouTubeRTMPS
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
          "Landscape Stream Key", selection: $appletData.landscapeYouTubeLiveStreamIDs[externalID]
        )
        .disabled(!outputSettings.youtubeSettings.ingestMode.usesLandscapeRTMPS)
        streamKeyPicker(
          "Portrait Stream Key", selection: $appletData.portraitYouTubeLiveStreamIDs[externalID]
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
    _ title: String, selection: Binding<String?>
  ) -> some View {
    VStack(alignment: .leading) {
      Picker(
        title,
        selection: Binding(
          get: { selection.wrappedValue },
          set: { selected in
            do {
              guard !isOutputActive else {
                throw WorkspaceSelectionError(message: "Stop output before changing a stream key.")
              }
              if selected != nil { _ = try appletData.loadYouTubeStreamKeyConfigurations() }
              guard
                selected == nil
                  || appletData.youtubeStreamKeyConfigurations.contains(where: { $0.id == selected }
                  )
              else {
                throw WorkspaceSelectionError(message: "The selected stream key no longer exists.")
              }
              selection.wrappedValue = selected
            } catch { reportError(error) }
          })
      ) {
        Text("Unassigned").tag(String?.none)
        ForEach(appletData.youtubeStreamKeyConfigurations) { configuration in
          Text(configuration.name).tag(Optional(configuration.id))
        }
        if let selected = selection.wrappedValue,
          !appletData.youtubeStreamKeyConfigurations.contains(where: { $0.id == selected })
        {
          Text("Unavailable").tag(Optional(selected))
        }
      }
      .pickerStyle(.menu)
      .disabled(isOutputActive)
      .onAppear(perform: refreshStreamKeys)
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

}

private struct RecordingFolderPicker: NSViewRepresentable {
  @Binding var path: String?
  @Environment(\.isEnabled) private var isEnabled

  func makeNSView(context: Context) -> NSPathControl {
    let control = NSPathControl()
    control.pathStyle = .popUp
    control.isEditable = true
    control.allowedTypes = [UTType.folder.identifier]
    control.placeholderString = String(localized: "(Default)")
    control.setAccessibilityLabel(String(localized: "Recording Folder"))
    control.delegate = context.coordinator
    control.target = context.coordinator
    control.action = #selector(Coordinator.pathChanged(_:))
    return control
  }

  func updateNSView(_ control: NSPathControl, context: Context) {
    context.coordinator.path = $path
    context.coordinator.isEnabled = isEnabled
    control.isEnabled = isEnabled
    let url = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    if control.url != url { control.url = url }
  }

  func makeCoordinator() -> Coordinator { Coordinator(path: $path) }

  @MainActor
  final class Coordinator: NSObject, NSPathControlDelegate {
    var path: Binding<String?>
    var isEnabled = true

    init(path: Binding<String?>) { self.path = path }

    @objc func pathChanged(_ control: NSPathControl) {
      guard isEnabled, control.clickedPathItem == nil else { return }
      path.wrappedValue = control.url?.standardizedFileURL.path
    }

    func pathControl(_ pathControl: NSPathControl, willDisplay openPanel: NSOpenPanel) {
      openPanel.canChooseDirectories = true
      openPanel.canChooseFiles = false
      openPanel.allowsMultipleSelection = false
    }

  }
}

#if DEBUG
  import Security

  @MainActor
  private enum WorkspaceOutputInspectorPreviewFixtures {
    static func makeStore(isOutputActive: Bool = false) -> WorkspaceStoreService {
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
      return WorkspaceStoreService(
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
    @Previewable @State var storeService = WorkspaceOutputInspectorPreviewFixtures.makeStore()
    @Previewable @State var appletData = WorkspaceOutputInspectorPreviewFixtures.makeAppletData()

    @Bindable var boundStore = storeService
    WorkspaceOutputInspector(
      outputSettings: $boundStore.outputSettings, externalID: UUID(),
      isOutputActive: storeService.isOutputActive, appletData: appletData,
      reportError: storeService.reportError
    )
    .frame(width: 480, height: 640)
  }

  #Preview("Output Active") {
    @Previewable @State var storeService = WorkspaceOutputInspectorPreviewFixtures.makeStore(
      isOutputActive: true)
    @Previewable @State var appletData = WorkspaceOutputInspectorPreviewFixtures.makeAppletData()

    @Bindable var boundStore = storeService
    WorkspaceOutputInspector(
      outputSettings: $boundStore.outputSettings, externalID: UUID(),
      isOutputActive: storeService.isOutputActive, appletData: appletData,
      reportError: storeService.reportError
    )
    .frame(width: 480, height: 640)
  }
#endif
