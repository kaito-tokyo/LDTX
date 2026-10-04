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
  @State private var volumeDrafts: [String: String] = [:]
  @State var errorMessage: String?

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
        Section {
          Grid(alignment: .center, horizontalSpacing: 8, verticalSpacing: 12) {
            GridRow {
              let key = "\(selectedProgram?.internalID ?? 0)/false"
              let volume = masterVolumeBinding(for: selectedProgram?.internalID, isPortrait: false)
              Label("Landscape", systemImage: "rectangle")
                .labelStyle(.iconOnly)
                .gridColumnAlignment(.center)
              MasterVolumeEditor(
                volume: volume, peakProvider: { audioPeakMeter.peak(for: .landscape) })
              TextField(
                "Volume",
                text: Binding(
                  get: { volumeDrafts[key] ?? String(format: "%.1f", volume.wrappedValue) },
                  set: { volumeDrafts[key] = $0 })
              )
              .frame(width: 50)
              .multilineTextAlignment(.trailing)
              .autocorrectionDisabled()
              .onSubmit {
                guard
                  let value = Double(
                    volumeDrafts[key] ?? String(format: "%.1f", volume.wrappedValue)),
                  value.isFinite,
                  (ProgramPreferences
                    .minimumAudioChannelGainDecibels...ProgramPreferences
                    .maximumAudioChannelGainDecibels).contains(value)
                else { return }
                volume.wrappedValue = (value * 10).rounded() / 10
              }
              Text("dB")
              if let draft = volumeDrafts[key],
                Double(draft).map({
                  $0.isFinite
                    && (ProgramPreferences
                      .minimumAudioChannelGainDecibels...ProgramPreferences
                      .maximumAudioChannelGainDecibels).contains($0)
                }) != true
              {
                Text("Invalid volume.")
              }
            }
            .accessibilityLabel("Landscape Volume")
            .disabled(selectedProgram == nil)
            GridRow {
              let key = "\(selectedProgram?.internalID ?? 0)/true"
              let volume = masterVolumeBinding(for: selectedProgram?.internalID, isPortrait: true)
              Label("Portrait", systemImage: "rectangle.portrait")
                .labelStyle(.iconOnly)
                .gridColumnAlignment(.center)
              MasterVolumeEditor(
                volume: volume, peakProvider: { audioPeakMeter.peak(for: .portrait) })
              TextField(
                "Volume",
                text: Binding(
                  get: { volumeDrafts[key] ?? String(format: "%.1f", volume.wrappedValue) },
                  set: { volumeDrafts[key] = $0 })
              )
              .frame(width: 50)
              .multilineTextAlignment(.trailing)
              .autocorrectionDisabled()
              .onSubmit {
                guard
                  let value = Double(
                    volumeDrafts[key] ?? String(format: "%.1f", volume.wrappedValue)),
                  value.isFinite,
                  (ProgramPreferences
                    .minimumAudioChannelGainDecibels...ProgramPreferences
                    .maximumAudioChannelGainDecibels).contains(value)
                else { return }
                volume.wrappedValue = (value * 10).rounded() / 10
              }
              Text("dB")
              if let draft = volumeDrafts[key],
                Double(draft).map({
                  $0.isFinite
                    && (ProgramPreferences
                      .minimumAudioChannelGainDecibels...ProgramPreferences
                      .maximumAudioChannelGainDecibels).contains($0)
                }) != true
              {
                Text("Invalid volume.")
              }
            }
            .accessibilityLabel("Portrait Volume")
            .disabled(selectedProgram == nil)
          }
          HStack {
            let volume = monitorVolumeBinding
            MonitorOutputDevicePicker()
            Slider(
              value: volume,
              in: ProgramPreferences
                .minimumAudioChannelGainDecibels...ProgramPreferences
                .maximumAudioChannelGainDecibels)
          }
          .accessibilityLabel("Monitor Volume")
        } header: {
          Text("Master Volumes").font(.headline)
        }

        Divider()

        Section {
          AudioMixEditor(
            uiState: uiState, appletData: appletData, workspaceURL: workspaceURL,
            programInternalID: selectedProgram?.internalID, audioInputs: audioInputs,
            audioPeakMeter: audioPeakMeter)
        } header: {
          Text("Audio Mix").font(.headline)
        }

        Divider()

        if let selectedProgram {
          let landscapePreference = uiState.preferences.landscapeProgramPreferences[
            selectedProgram.internalID]
          let portraitPreference = uiState.preferences.portraitProgramPreferences[
            selectedProgram.internalID]
          VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading) {
              Text("Landscape Video Layers").font(.headline)
              VideoLayersEditor(
                uiState: uiState,
                transforms: landscapePreference?.videoLayerTransforms ?? [:],
                hidden: landscapePreference?.videoLayerHidden ?? [:],
                width: 1920, height: 1080,
                layerIDs: selectedProgram.landscapeVideoLayerInternalIds
              ) { internalID, action in
                performVideoLayerAction(
                  internalID, action: action, programInternalID: selectedProgram.internalID,
                  isPortrait: false)
              } onCommitTransform: { internalID, transform in
                guard let workspaceDispatcher else {
                  throw NSError(
                    domain: "Workspace", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Workspace is unavailable."])
                }
                try workspaceDispatcher.setBasicTransform(
                  transform, programInternalID: selectedProgram.internalID,
                  videoLayerInternalID: internalID, isPortrait: false)
              }
            }
            Divider()
            VStack(alignment: .leading) {
              Text("Portrait Video Layers").font(.headline)
              VideoLayersEditor(
                uiState: uiState,
                transforms: portraitPreference?.videoLayerTransforms ?? [:],
                hidden: portraitPreference?.videoLayerHidden ?? [:],
                width: 1080, height: 1920,
                layerIDs: selectedProgram.portraitVideoLayerInternalIds
              ) { internalID, action in
                performVideoLayerAction(
                  internalID, action: action, programInternalID: selectedProgram.internalID,
                  isPortrait: true)
              } onCommitTransform: { internalID, transform in
                guard let workspaceDispatcher else {
                  throw NSError(
                    domain: "Workspace", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Workspace is unavailable."])
                }
                try workspaceDispatcher.setBasicTransform(
                  transform, programInternalID: selectedProgram.internalID,
                  videoLayerInternalID: internalID, isPortrait: true)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .id(selectedProgram.internalID)
        } else {
          Text("No program selected").foregroundStyle(.secondary)
        }

        if let errorMessage {
          Text(errorMessage).foregroundStyle(.red)
        }
        if let message = uiState.outputFailureMessage {
          Text(message).foregroundStyle(.red)
        }
        Spacer()
      }
      .padding(20)
    }
    .onAppear {
      workspaceDispatcher?.synchronizeAudioMonitor()
    }
  }

  private func masterVolumeBinding(
    for programInternalID: UInt64?,
    isPortrait: Bool
  ) -> Binding<Double> {
    Binding(
      get: {
        let preference = programInternalID.flatMap {
          (isPortrait
            ? uiState.preferences.portraitProgramPreferences
            : uiState.preferences.landscapeProgramPreferences)[$0]
        }
        return Double(preference?.audioMasterVolumeDecibelTenths ?? 0) / 10
      },
      set: { value in
        guard let programInternalID else { return }
        volumeDrafts["\(programInternalID)/\(isPortrait)"] = String(format: "%.1f", value)
        var preferences = uiState.preferences
        var preference =
          (isPortrait
          ? preferences.portraitProgramPreferences : preferences.landscapeProgramPreferences)[
            programInternalID] ?? .init()
        preference.audioMasterVolumeDecibelTenths = Int32((value * 10).rounded())
        if isPortrait {
          preferences.portraitProgramPreferences[programInternalID] = preference
        } else {
          preferences.landscapeProgramPreferences[programInternalID] = preference
        }
        uiState.preferences = preferences
        workspaceDispatcher?.updateMixPreferences()
        workspaceDispatcher?.synchronizeAudioMonitor()
      })
  }

  private var monitorVolumeBinding: Binding<Double> {
    Binding(
      get: { localState.monitorVolume ?? 0 },
      set: { value in
        var state = localState
        state.monitorVolume = value
        setLocalState(state)
        workspaceDispatcher?.synchronizeAudioMonitor()
      })
  }

  private var audioInputs: [Ldtx_Workspace_V4_AudioInputDevice] {
    uiState.definition.inputDevices.compactMap { input in
      guard case .audioDevice(let device)? = input.definition else { return nil }
      return device
    }
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
      var preference = Ldtx_Workspace_V4_ProgramPreferences()
      preference.videoLayerTransforms = [1: transform, 4: transform, 3: transform]
      state.preferences.landscapeProgramPreferences[program.internalID] = preference
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
