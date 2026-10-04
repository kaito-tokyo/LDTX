// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

struct AudioMixEditor: View {
  let landscapePreferences: Ldtx_Workspace_V4_ProgramPreferences
  let portraitPreferences: Ldtx_Workspace_V4_ProgramPreferences
  let selectedPreferences: Ldtx_Workspace_V4_ProgramPreferences
  let isEnabled: Bool
  let canMonitor: Bool
  let monitoredInputIDs: Set<UInt64>
  let audioInputs: [Ldtx_Workspace_V4_AudioInputDevice]
  let audioPeakMeter: ProgramAudioPeakMeter
  let gainAccessibilityLabel: (Ldtx_Workspace_V4_AudioInputDevice) -> String
  let onSetLandscapeMuted: (UInt64, Bool) -> Void
  let onSetPortraitMuted: (UInt64, Bool) -> Void
  let onSetGain: (UInt64, Int32) -> Void
  let onSetMonitor: (UInt64, Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(audioInputs, id: \.internalID) { input in
        VStack(spacing: 4) {
          HStack {
            Text(input.displayName)
            Spacer()
            Toggle(
              "Landscape",
              isOn: Binding(
                get: { landscapePreferences.audioChannelMuted[input.internalID] != true },
                set: { onSetLandscapeMuted(input.internalID, !$0) })
            )
            .toggleStyle(.checkbox).help("Landscape")
            .accessibilityLabel("Landscape " + input.displayName)
            .disabled(!isEnabled)
            Toggle(
              "Portrait",
              isOn: Binding(
                get: { portraitPreferences.audioChannelMuted[input.internalID] != true },
                set: { onSetPortraitMuted(input.internalID, !$0) })
            )
            .toggleStyle(.checkbox).help("Portrait")
            .accessibilityLabel("Portrait " + input.displayName)
            .disabled(!isEnabled)
            Toggle(
              "Monitor",
              isOn: Binding(
                get: { monitoredInputIDs.contains(input.internalID) },
                set: { onSetMonitor(input.internalID, $0) })
            )
            .toggleStyle(.checkbox).help("Monitor")
            .accessibilityLabel("Monitor " + input.displayName)
            .disabled(!canMonitor)
          }
          AudioChannelControl(
            label: "",
            value: ProgramPreferences.linearAudioChannelGain(
              fromDecibels:
                Double(selectedPreferences.audioChannelGainsDecibelTenths[input.internalID] ?? 0)
                / 10),
            peakProvider: { audioPeakMeter.peak(for: "v4-\(input.internalID)") },
            onPreview: { gain in
              let decibels = ProgramPreferences.audioChannelGainDecibels(fromLinearGain: gain)
              onSetGain(input.internalID, Int32((decibels * 10).rounded()))
            }, onCommit: { _ in }
          )
          .disabled(!isEnabled)
          .accessibilityLabel(gainAccessibilityLabel(input))
        }
      }
    }
  }
}
