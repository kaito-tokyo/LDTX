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
              let key = "\(selectedProgram?.internalID ?? 0)/sdr-1080p60"
              let volume = masterVolumeBinding(for: selectedProgram?.internalID, target: .landscape)
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
              let key = "\(selectedProgram?.internalID ?? 0)/sdr-portrait-1080p60"
              let volume = masterVolumeBinding(for: selectedProgram?.internalID, target: .portrait)
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
          let programID = selectedProgram?.internalID
          let landscape =
            programID.flatMap { uiState.preferences.landscapeProgramPreferences[$0] } ?? .init()
          let portrait =
            programID.flatMap { uiState.preferences.portraitProgramPreferences[$0] } ?? .init()
          let selectedPreferences = uiState.selectedAudioMix == .landscape ? landscape : portrait
          let selectedTarget: WorkspaceCanvasTarget =
            uiState.selectedAudioMix == .landscape ? .landscape : .portrait
          AudioMixEditor(
            landscapePreferences: landscape, portraitPreferences: portrait,
            selectedPreferences: selectedPreferences,
            isEnabled: programID != nil, canMonitor: workspaceURL != nil,
            monitoredInputIDs: localState.monitorAudioInputDeviceInternalIDs,
            audioInputs: audioInputs, audioPeakMeter: audioPeakMeter,
            gainAccessibilityLabel: { input in
              switch uiState.selectedAudioMix {
              case .landscape: return "Landscape " + input.displayName + " Gain"
              case .portrait: return "Portrait " + input.displayName + " Gain"
              }
            },
            onSetLandscapeMuted: { id, value in
              updateCanvasPreferences(for: programID, target: .landscape) {
                $0.audioChannelMuted[id] = value
              }
            },
            onSetPortraitMuted: { id, value in
              updateCanvasPreferences(for: programID, target: .portrait) {
                $0.audioChannelMuted[id] = value
              }
            },
            onSetGain: { id, value in
              updateCanvasPreferences(for: programID, target: selectedTarget) {
                $0.audioChannelGainsDecibelTenths[id] = value
              }
            },
            onSetMonitor: { id, enabled in
              guard let workspaceURL else { return }
              appletData.updateState(for: workspaceURL) { state in
                if enabled {
                  state.monitorAudioInputDeviceInternalIDs.insert(id)
                } else {
                  state.monitorAudioInputDeviceInternalIDs.remove(id)
                }
              }
              workspaceDispatcher?.synchronizeAudioMonitor()
            })
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
                definition: uiState.definition, isLayerFrozen: uiState.isOutputActive,
                programPreferences: landscapePreference ?? .init(),
                canvasWidth: 1920, canvasHeight: 1080,
                layerIDs: selectedProgram.landscapeVideoLayerInternalIds
              ) { internalID, action in
                performVideoLayerAction(
                  internalID, action: action, programInternalID: selectedProgram.internalID,
                  target: .landscape)
              } onCommitTransform: { internalID, transform in
                guard let workspaceDispatcher else {
                  throw NSError(
                    domain: "Workspace", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Workspace is unavailable."])
                }
                try workspaceDispatcher.setBasicTransform(
                  transform, programInternalID: selectedProgram.internalID,
                  videoLayerInternalID: internalID, target: .landscape)
              }
            }
            Divider()
            VStack(alignment: .leading) {
              Text("Portrait Video Layers").font(.headline)
              VideoLayersEditor(
                definition: uiState.definition, isLayerFrozen: uiState.isOutputActive,
                programPreferences: portraitPreference ?? .init(),
                canvasWidth: 1080, canvasHeight: 1920,
                layerIDs: selectedProgram.portraitVideoLayerInternalIds
              ) { internalID, action in
                performVideoLayerAction(
                  internalID, action: action, programInternalID: selectedProgram.internalID,
                  target: .portrait)
              } onCommitTransform: { internalID, transform in
                guard let workspaceDispatcher else {
                  throw NSError(
                    domain: "Workspace", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Workspace is unavailable."])
                }
                try workspaceDispatcher.setBasicTransform(
                  transform, programInternalID: selectedProgram.internalID,
                  videoLayerInternalID: internalID, target: .portrait)
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
    for programInternalID: UInt64?, target: WorkspaceCanvasTarget
  ) -> Binding<Double> {
    Binding(
      get: {
        let preference = programInternalID.flatMap {
          uiState.preferences[keyPath: target.preferences][$0]
        }
        return Double(preference?.audioMasterVolumeDecibelTenths ?? 0) / 10
      },
      set: { value in
        guard let programInternalID else { return }
        let key = "\(programInternalID)/\(target.defaultProfile.id)"
        volumeDrafts[key] = String(format: "%.1f", value)
        updateCanvasPreferences(for: programInternalID, target: target) {
          $0.audioMasterVolumeDecibelTenths = Int32((value * 10).rounded())
        }
      })
  }

  private func updateCanvasPreferences(
    for programInternalID: UInt64?, target: WorkspaceCanvasTarget,
    mutation: (inout Ldtx_Workspace_V4_ProgramPreferences) -> Void
  ) {
    guard let programInternalID,
      uiState.definition.programs.contains(where: { $0.internalID == programInternalID })
    else { return }
    var preferences = uiState.preferences
    var preference = preferences[keyPath: target.preferences][programInternalID] ?? .init()
    mutation(&preference)
    preferences[keyPath: target.preferences][programInternalID] = preference
    uiState.preferences = preferences
    workspaceDispatcher?.updateMixPreferences()
    workspaceDispatcher?.synchronizeAudioMonitor()
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
