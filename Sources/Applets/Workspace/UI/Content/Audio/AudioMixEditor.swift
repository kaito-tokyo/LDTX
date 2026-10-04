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
  let programInternalID: UInt64
  let audioInputs: [Ldtx_Workspace_V4_AudioInputDevice]
  let isAudioMixSynced: Bool
  let audioPeakMeter: ProgramAudioPeakMeter

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      audioMasterControl(
        "Landscape", symbol: "rectangle",
        value: masterVolumeBinding(for: programInternalID, isPortrait: false),
        meter: .landscape
      )
      audioMasterControl(
        "Portrait", symbol: "rectangle.portrait",
        value: masterVolumeBinding(for: programInternalID, isPortrait: true), meter: .portrait
      )
      .disabled(isAudioMixSynced)
      VStack(alignment: .leading, spacing: 4) {
        audioMasterControl("Monitor", symbol: "headphones", value: monitorVolumeBinding)
        MonitorOutputDevicePicker().padding(.leading, 28)
      }
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
            .disabled(isAudioMixSynced)
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
          .disabled(uiState.isPortraitAudio && isAudioMixSynced)
          .accessibilityLabel(
            (!uiState.isPortraitAudio ? "Landscape " : "Portrait ") + input.displayName
              + " Gain")
        }
      }
    }
  }

  private func audioMasterControl(
    _ name: String, symbol: String, value: Binding<Double>,
    meter: ProgramAudioPeakMeter.Master? = nil
  ) -> some View {
    HStack(spacing: 8) {
      Image(systemName: symbol).frame(width: 20).accessibilityHidden(true)
      AudioChannelControl(
        label: "",
        value: ProgramPreferences.linearAudioChannelGain(fromDecibels: value.wrappedValue),
        peakProvider: meter.map { bus in { audioPeakMeter.peak(for: bus) } },
        onPreview: {
          value.wrappedValue = ProgramPreferences.audioChannelGainDecibels(fromLinearGain: $0)
        },
        onCommit: { _ in }
      )
      .accessibilityLabel(name + " Master Volume")
    }
    .help(name + " Master Volume")
  }

  private func audioConnectionToggle(
    _ input: Ldtx_Workspace_V4_AudioInputDevice, programInternalID: UInt64, isPortrait: Bool
  ) -> some View {
    let muted = audioMuteBinding(
      for: input.internalID, programInternalID: programInternalID, isPortrait: isPortrait)
    let connected = Binding(get: { !muted.wrappedValue }, set: { muted.wrappedValue = !$0 })
    let name = !isPortrait ? "Landscape" : "Portrait"
    return Toggle(name, isOn: connected)
      .toggleStyle(.checkbox)
      .help(name)
      .accessibilityLabel(name + " " + input.displayName)
  }

  private func masterVolumeBinding(
    for programInternalID: UInt64,
    isPortrait: Bool
  ) -> Binding<Double> {
    Binding(
      get: {
        let preference = uiState.preferences.programPreferences[
          programInternalID]
        return !isPortrait || isAudioMixSynced
          ? preference?.landscapeMasterVolume ?? 0 : preference?.portraitMasterVolume ?? 0
      },
      set: { value in
        var preferences = uiState.preferences
        var preference = preferences.programPreferences[programInternalID] ?? .init()
        if !isPortrait {
          preference.landscapeMasterVolume = value
        } else {
          preference.portraitMasterVolume = value
        }
        preferences.programPreferences[programInternalID] = preference
        uiState.preferences = preferences
        workspaceDispatcher?.updateMixPreferences()
        workspaceDispatcher?.synchronizeAudioMonitor()
      })
  }

  private func audioGainBinding(
    for inputDeviceInternalID: UInt64,
    programInternalID: UInt64,
    isPortrait: Bool
  ) -> Binding<Double> {
    Binding(
      get: {
        let preference = uiState.preferences.programPreferences[
          programInternalID]
        return !isPortrait || isAudioMixSynced
          ? preference?.landscapeAudioChannelGains[inputDeviceInternalID] ?? 0
          : preference?.portraitAudioChannelGains[inputDeviceInternalID] ?? 0
      },
      set: { value in
        var preferences = uiState.preferences
        var preference = preferences.programPreferences[programInternalID] ?? .init()
        if !isPortrait {
          preference.landscapeAudioChannelGains[inputDeviceInternalID] = value
        } else {
          preference.portraitAudioChannelGains[inputDeviceInternalID] = value
        }
        preferences.programPreferences[programInternalID] = preference
        uiState.preferences = preferences
        workspaceDispatcher?.updateMixPreferences()
        workspaceDispatcher?.synchronizeAudioMonitor()
      })
  }

  private func audioMuteBinding(
    for inputDeviceInternalID: UInt64,
    programInternalID: UInt64,
    isPortrait: Bool
  ) -> Binding<Bool> {
    Binding(
      get: {
        let preference = uiState.preferences.programPreferences[
          programInternalID]
        return !isPortrait || isAudioMixSynced
          ? preference?.landscapeAudioChannelMuted[inputDeviceInternalID] ?? false
          : preference?.portraitAudioChannelMuted[inputDeviceInternalID] ?? false
      },
      set: { value in
        var preferences = uiState.preferences
        var preference = preferences.programPreferences[programInternalID] ?? .init()
        if !isPortrait {
          preference.landscapeAudioChannelMuted[inputDeviceInternalID] = value
        } else {
          preference.portraitAudioChannelMuted[inputDeviceInternalID] = value
        }
        preferences.programPreferences[programInternalID] = preference
        uiState.preferences = preferences
        workspaceDispatcher?.updateMixPreferences()
        workspaceDispatcher?.synchronizeAudioMonitor()
      })
  }

  private var monitorVolumeBinding: Binding<Double> {
    Binding(
      get: { uiState.preferences.monitorVolume },
      set: { value in
        var preferences = uiState.preferences
        preferences.monitorVolume = value
        uiState.preferences = preferences
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
