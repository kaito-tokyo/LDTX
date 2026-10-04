// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

struct AudioMixEditor: View {
  @Environment(\.workspaceDispatcher) private var workspaceDispatcher
  @Bindable var uiState: WorkspaceUIState
  let appletData: WorkspaceAppletData
  let workspaceURL: URL?
  let programInternalID: UInt64?
  let audioInputs: [Ldtx_Workspace_V4_AudioInputDevice]
  let audioPeakMeter: ProgramAudioPeakMeter

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(audioInputs, id: \.internalID) { input in
        VStack(spacing: 4) {
          HStack {
            Text(input.displayName)
            Spacer()
            audioConnectionToggle(
              input, programInternalID: programInternalID, isPortrait: false)
            audioConnectionToggle(
              input, programInternalID: programInternalID, isPortrait: true
            )
            .disabled(programInternalID == nil)
            let monitored = monitorBinding(for: input.internalID)
            Toggle("Monitor", isOn: monitored)
              .toggleStyle(.checkbox)
              .help("Monitor")
              .accessibilityLabel("Monitor " + input.displayName)
              .disabled(workspaceURL == nil)
          }
          let gain = audioGainBinding(
            for: input.internalID, programInternalID: programInternalID,
            isPortrait: uiState.isPortraitAudio)
          AudioChannelControl(
            label: "",
            value: ProgramPreferences.linearAudioChannelGain(fromDecibels: gain.wrappedValue),
            peakProvider: { audioPeakMeter.peak(for: "v4-\(input.internalID)") },
            onPreview: {
              gain.wrappedValue = ProgramPreferences.audioChannelGainDecibels(
                fromLinearGain: $0)
            },
            onCommit: { _ in }
          )
          .disabled(programInternalID == nil)
          .accessibilityLabel(
            (!uiState.isPortraitAudio ? "Landscape " : "Portrait ") + input.displayName
              + " Gain")
        }
      }
    }
  }

  private func audioConnectionToggle(
    _ input: Ldtx_Workspace_V4_AudioInputDevice, programInternalID: UInt64?, isPortrait: Bool
  ) -> some View {
    let muted = audioMuteBinding(
      for: input.internalID, programInternalID: programInternalID, isPortrait: isPortrait)
    let connected = Binding(get: { !muted.wrappedValue }, set: { muted.wrappedValue = !$0 })
    let name = !isPortrait ? "Landscape" : "Portrait"
    return Toggle(name, isOn: connected)
      .disabled(programInternalID == nil)
      .toggleStyle(.checkbox)
      .help(name)
      .accessibilityLabel(name + " " + input.displayName)
  }

  private func audioGainBinding(
    for inputDeviceInternalID: UInt64,
    programInternalID: UInt64?,
    isPortrait: Bool
  ) -> Binding<Double> {
    Binding(
      get: {
        let preference = programInternalID.flatMap {
          (isPortrait
            ? uiState.preferences.portraitProgramPreferences
            : uiState.preferences.landscapeProgramPreferences)[$0]
        }
        return Double(preference?.audioChannelGainsDecibelTenths[inputDeviceInternalID] ?? 0) / 10
      },
      set: { value in
        guard let programInternalID else { return }
        var preferences = uiState.preferences
        var preference =
          (isPortrait
          ? preferences.portraitProgramPreferences : preferences.landscapeProgramPreferences)[
            programInternalID] ?? .init()
        preference.audioChannelGainsDecibelTenths[inputDeviceInternalID] = Int32(
          (value * 10).rounded())
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

  private func audioMuteBinding(
    for inputDeviceInternalID: UInt64,
    programInternalID: UInt64?,
    isPortrait: Bool
  ) -> Binding<Bool> {
    Binding(
      get: {
        let preference = programInternalID.flatMap {
          (isPortrait
            ? uiState.preferences.portraitProgramPreferences
            : uiState.preferences.landscapeProgramPreferences)[$0]
        }
        return preference?.audioChannelMuted[inputDeviceInternalID] ?? false
      },
      set: { value in
        guard let programInternalID else { return }
        var preferences = uiState.preferences
        var preference =
          (isPortrait
          ? preferences.portraitProgramPreferences : preferences.landscapeProgramPreferences)[
            programInternalID] ?? .init()
        preference.audioChannelMuted[inputDeviceInternalID] = value
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

  private func monitorBinding(for inputDeviceInternalID: UInt64) -> Binding<Bool> {
    Binding(
      get: {
        workspaceURL.map {
          appletData.state(for: $0).monitorAudioInputDeviceInternalIDs.contains(
            inputDeviceInternalID)
        } ?? false
      },
      set: { enabled in
        guard let workspaceURL else { return }
        appletData.updateState(for: workspaceURL) { state in
          if enabled {
            state.monitorAudioInputDeviceInternalIDs.insert(inputDeviceInternalID)
          } else {
            state.monitorAudioInputDeviceInternalIDs.remove(inputDeviceInternalID)
          }
        }
        workspaceDispatcher?.synchronizeAudioMonitor()
      })
  }

}
