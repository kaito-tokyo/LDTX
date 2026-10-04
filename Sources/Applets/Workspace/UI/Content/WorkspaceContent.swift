// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppletSupport
import LDTXWorkspaceAppletInterface
import SwiftUI

public struct WorkspaceContent: View {
  @Environment(\.documentReference) private var documentReference
  var workspaceURL: URL? {
    guard let document = documentReference?.document else { return nil }
    return document.fileURL ?? uiState.localStateURL
  }
  @Environment(\.workspaceDispatcher) var workspaceDispatcher
  let audioPeakMeter: ProgramAudioPeakMeter
  @Bindable var uiState: WorkspaceUIState
  @Bindable var appletData: WorkspaceAppletData
  @State var errorMessage: String?
  @State var transformDrafts: [String: [String]] = [:]

  public init(
    uiState: WorkspaceUIState,
    appletData: WorkspaceAppletData,
    audioPeakMeter: ProgramAudioPeakMeter
  ) {
    self.audioPeakMeter = audioPeakMeter
    self._uiState = Bindable(wrappedValue: uiState)
    self._appletData = Bindable(wrappedValue: appletData)
  }

  public var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading) {
        if let program = selectedProgram, !audioInputs.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("Audio Mix").font(.headline)
              Spacer()
              Toggle("Sync", isOn: audioMixSyncBinding)
                .toggleStyle(.switch)
                .disabled(workspaceURL == nil)
            }
            AudioMixEditor(
              uiState: uiState, appletData: appletData, workspaceURL: workspaceURL,
              programInternalID: program.internalID, audioInputs: audioInputs,
              isAudioMixSynced: isAudioMixSynced, audioPeakMeter: audioPeakMeter)
          }
        }
        if let selectedProgram {
          Divider()
          let preference = uiState.preferences.programPreferences[selectedProgram.internalID]
          VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading) {
              Text("Landscape Video Layers").font(.headline)
              VideoLayersEditor(
                uiState: uiState,
                transforms: preference?.landscapeVideoLayerTransforms ?? [:],
                muted: preference?.landscapeVideoLayerMuted ?? [:],
                width: 1920, height: 1080,
                draftKeyPrefix: "\(selectedProgram.internalID)/false",
                layerIDs: selectedProgram.landscapeVideoLayerInternalIds,
                transformDrafts: $transformDrafts
              ) { internalID, action in
                performVideoLayerAction(
                  internalID, action: action, programInternalID: selectedProgram.internalID,
                  isPortrait: false)
              }
            }
            Divider()
            VStack(alignment: .leading) {
              Text("Portrait Video Layers").font(.headline)
              VideoLayersEditor(
                uiState: uiState,
                transforms: preference?.portraitVideoLayerTransforms ?? [:],
                muted: preference?.portraitVideoLayerMuted ?? [:],
                width: 1080, height: 1920,
                draftKeyPrefix: "\(selectedProgram.internalID)/true",
                layerIDs: selectedProgram.portraitVideoLayerInternalIds,
                transformDrafts: $transformDrafts
              ) { internalID, action in
                performVideoLayerAction(
                  internalID, action: action, programInternalID: selectedProgram.internalID,
                  isPortrait: true)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .id(selectedProgram.internalID)
        }
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        if let message = uiState.outputFailureMessage {
          Text(message).foregroundStyle(.red)
        }
        Spacer()
      }
      .padding(20)
      .padding(.bottom, pendingTransforms.isEmpty ? 0 : 48)
    }
    .onSubmit { applyChanges() }
    .overlay(alignment: .bottomTrailing) {
      if !pendingTransforms.isEmpty {
        Button("Apply Changes") { applyChanges() }
          .disabled(pendingTransforms.contains { $0.transform == nil })
          .padding(20)
      }
    }
    .onAppear {
      workspaceDispatcher?.synchronizeAudioMonitor()
    }
  }

  var pendingTransforms:
    [(
      key: String, programID: UInt64, layerID: UInt64,
      isPortrait: Bool, transform: Ldtx_Workspace_V4_BasicTransform?
    )]
  {
    var result: [(String, UInt64, UInt64, Bool, Ldtx_Workspace_V4_BasicTransform?)] = []
    for program in uiState.definition.programs {
      let preference = uiState.preferences.programPreferences[program.internalID]
      for isPortrait in [false, true] {
        let width = Double(isPortrait ? 1080 : 1920)
        let height = Double(isPortrait ? 1920 : 1080)
        let layerIDs =
          isPortrait
          ? program.portraitVideoLayerInternalIds
          : program.landscapeVideoLayerInternalIds
        for layerID in layerIDs {
          let key = "\(program.internalID)/\(isPortrait)/\(layerID)"
          guard let strings = transformDrafts[key] else { continue }
          let current =
            (isPortrait
              ? preference?.portraitVideoLayerTransforms[layerID]
              : preference?.landscapeVideoLayerTransforms[layerID]) ?? .init()
          let initial = [
            String(Double(current.translationX) * width),
            String(Double(current.translationY) * height),
            String(current.scaleX), String(current.scaleY),
          ]
          guard strings != initial else { continue }
          let values = strings.compactMap { Double($0) }
          var transform: Ldtx_Workspace_V4_BasicTransform?
          if values.count == 4 && values.allSatisfy(\.isFinite) {
            let numbers = [
              Float(values[0] / width), Float(values[1] / height),
              Float(values[2]), Float(values[3]),
            ]
            if numbers.allSatisfy(\.isFinite) {
              transform = .init(
                translationX: numbers[0], translationY: numbers[1],
                scaleX: numbers[2], scaleY: numbers[3])
            }
          }
          result.append((key, program.internalID, layerID, isPortrait, transform))
        }
      }
    }
    return result
  }

  func applyChanges() {
    let changes = pendingTransforms
    guard let workspaceDispatcher, changes.allSatisfy({ $0.transform != nil }) else { return }
    do {
      for change in changes {
        guard let transform = change.transform else { continue }
        try workspaceDispatcher.setBasicTransform(
          transform, programInternalID: change.programID,
          videoLayerInternalID: change.layerID, isPortrait: change.isPortrait)
        transformDrafts.removeValue(forKey: change.key)
      }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private var audioInputs: [Ldtx_Workspace_V4_AudioInputDevice] {
    uiState.definition.inputDevices.compactMap { input in
      guard case .audioDevice(let device)? = input.definition else { return nil }
      return device
    }
  }

  private var isAudioMixSynced: Bool {
    guard let program = selectedProgram else { return false }
    return localState.synchronizesLandscapeMixToPortraitByProgramInternalID[program.internalID]
      ?? false
  }

  private var audioMixSyncBinding: Binding<Bool> {
    Binding(
      get: { isAudioMixSynced },
      set: { value in
        guard let program = selectedProgram else { return }
        var state = localState
        state.synchronizesLandscapeMixToPortraitByProgramInternalID[program.internalID] = value
        setLocalState(state)
        workspaceDispatcher?.updateMixPreferences()
        workspaceDispatcher?.synchronizeAudioMonitor()
      })
  }

  var selectedProgram: Ldtx_Workspace_V4_ProgramDefinition? {
    uiState.definition.programs.first { $0.internalID == localState.selectedProgramInternalID }
      ?? uiState.definition.programs.first
  }

  var localState: WorkspaceLocalState {
    guard let workspaceURL else { return .init() }
    return appletData.state(for: workspaceURL)
  }

  func setLocalState(_ state: WorkspaceLocalState) {
    guard let workspaceURL else { return }
    appletData.setState(state, for: workspaceURL)
    workspaceDispatcher?.updateProgramRuntimes()
  }
}

#if DEBUG
  #Preview("Workspace Content") {
    @Previewable @State var uiState: WorkspaceUIState = {
      let state = WorkspaceSidebarPreviewFixtures.makeUIState()
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 100
      program.displayName = "Preview Program"
      program.landscapeVideoLayerInternalIds = [1, 4, 3]
      state.definition.programs = [program]
      var transform = Ldtx_Workspace_V4_BasicTransform()
      transform.scaleX = 1
      transform.scaleY = 1
      var preference = Ldtx_Workspace_V4_ProgramPreference()
      preference.landscapeVideoLayerTransforms = [1: transform, 4: transform, 3: transform]
      state.preferences.programPreferences[program.internalID] = preference
      return state
    }()
    @Previewable @State var appletData = WorkspaceAppletData(
      userDefaults: UserDefaults(suiteName: "WorkspaceContentPreview")!)

    WorkspaceContent(
      uiState: uiState,
      appletData: appletData,
      audioPeakMeter: ProgramAudioPeakMeter()
    )
    .frame(width: 720, height: 1000)
  }
#endif
