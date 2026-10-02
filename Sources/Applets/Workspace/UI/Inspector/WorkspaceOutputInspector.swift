// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppletSupport
import LDTXWorkspaceAppletInterface
import SwiftUI

struct WorkspaceOutputInspector: View {
  @Environment(\.documentReference) private var documentReference
  private var workspaceURL: URL? {
    guard let document = documentReference?.document else { return nil }
    return document.fileURL ?? uiState.localStateURL
  }
  let uiState: WorkspaceUIState
  @Bindable var appletData: WorkspaceAppletData
  @State private var isShowingStreamKeyManager = false
  @State private var streamKeyLoadError: String?

  var body: some View {
    Form {
      formContent
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private var formContent: some View {
    Section("Output") {
      TextField("Recording Folder", text: outputFolderPathBinding)
      Toggle("Record Landscape", isOn: outputBinding(\.recordsLandscape))
      Toggle("Record Portrait", isOn: outputBinding(\.recordsPortrait))
      Toggle("Stream to YouTube", isOn: outputBinding(\.streamsToYoutube))
      Picker("YouTube Ingest", selection: ingestModeBinding) {
        ForEach(ingestModes, id: \.rawValue) { mode in
          Text(ingestModeLabel(mode)).tag(mode)
        }
      }
      if !isAvailableIngestMode(
        uiState.definition.outputConfiguration.resolvedYouTubeIngestMode)
      {
        Text("This YouTube ingest mode is not available yet.")
          .foregroundStyle(.secondary)
      }
      if usesLandscapeRTMPS {
        streamKeyPicker("Landscape Stream Key", selection: landscapeStreamKeyBinding)
      }
      if usesPortraitRTMPS {
        streamKeyPicker("Portrait Stream Key", selection: portraitStreamKeyBinding)
      }
      Button("Manage Stream Keys") { isShowingStreamKeyManager = true }
        .popover(isPresented: $isShowingStreamKeyManager) {
          WorkspaceV4StreamKeyManager(
            configurations: appletData.youtubeStreamKeyConfigurations,
            load: { try appletData.loadYouTubeStreamKeyConfigurations() },
            save: { try appletData.saveYouTubeStreamKeyConfigurations($0) }
          )
        }
      if let streamKeyLoadError {
        Text(streamKeyLoadError).foregroundStyle(.red)
      }
    }
    .disabled(uiState.isOutputActive)
    .onAppear {
      do {
        _ = try appletData.loadYouTubeStreamKeyConfigurations()
        streamKeyLoadError = nil
      } catch {
        streamKeyLoadError = error.localizedDescription
      }
    }

  }

  private var ingestModes: [Ldtx_Workspace_V4_YouTubeIngestMode] {
    [.landscapeRtmps, .portraitRtmps, .dualRtmps]
  }

  private func outputBinding(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_OutputConfiguration, Bool>
  ) -> Binding<Bool> {
    Binding(
      get: { uiState.definition.outputConfiguration[keyPath: keyPath] },
      set: { value in
        var definition = uiState.definition
        definition.outputConfiguration[keyPath: keyPath] = value
        uiState.definition = definition
      }
    )
  }

  private var ingestModeBinding: Binding<Ldtx_Workspace_V4_YouTubeIngestMode> {
    Binding(
      get: { uiState.definition.outputConfiguration.resolvedYouTubeIngestMode },
      set: { value in
        var definition = uiState.definition
        definition.outputConfiguration.youtubeIngestMode = value
        uiState.definition = definition
      }
    )
  }

  private var outputFolderPathBinding: Binding<String> {
    Binding(
      get: {
        let output = uiState.definition.outputConfiguration
        return output.hasOutputFolderPath ? output.outputFolderPath : ""
      },
      set: { path in
        var definition = uiState.definition
        if path.isEmpty {
          definition.outputConfiguration.clearOutputFolderPath()
        } else {
          definition.outputConfiguration.outputFolderPath = path
        }
        uiState.definition = definition
      }
    )
  }

  private var usesLandscapeRTMPS: Bool {
    switch uiState.definition.outputConfiguration.resolvedYouTubeIngestMode {
    case .landscapeRtmps, .dualRtmps: true
    default: false
    }
  }

  private var usesPortraitRTMPS: Bool {
    switch uiState.definition.outputConfiguration.resolvedYouTubeIngestMode {
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

  private var landscapeStreamKeyBinding: Binding<String> {
    Binding(
      get: { localState.landscapeYouTubeLiveStreamID ?? "" },
      set: { streamID in
        guard let workspaceURL else { return }
        appletData.updateState(for: workspaceURL) {
          $0.landscapeYouTubeLiveStreamID = streamID.isEmpty ? nil : streamID
        }
      })
  }

  private var portraitStreamKeyBinding: Binding<String> {
    Binding(
      get: { localState.portraitYouTubeLiveStreamID ?? "" },
      set: { streamID in
        guard let workspaceURL else { return }
        appletData.updateState(for: workspaceURL) {
          $0.portraitYouTubeLiveStreamID = streamID.isEmpty ? nil : streamID
        }
      })
  }

  private var localState: WorkspaceLocalState {
    guard let workspaceURL else { return .init() }
    return appletData.state(for: workspaceURL)
  }

  private func streamKeyPicker(_ title: String, selection: Binding<String>) -> some View {
    Picker(title, selection: selection) {
      Text("Select Stream Key").tag("")
      ForEach(appletData.youtubeStreamKeyConfigurations) { configuration in
        Text(configuration.name).tag(configuration.id)
      }
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
