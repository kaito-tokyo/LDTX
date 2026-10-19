// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgramRuntime
import LDTXProtos
import LDTXWorkspaceAppletModel
import SwiftUI

struct AudioMixEditor: View {
  @Environment(\.undoManager) private var undoManager
  let stateService: WorkspaceDocument
  let appletData: WorkspaceAppletData
  let peakMeter: ProgramAudioPeakMeter
  let reportError: (Error) -> Void
  var runtimeActions: () -> (any WorkspaceRuntimeActions)? = { nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Audio Mix").fontWeight(.semibold)
      ForEach(stateService.workspaceDefinition.audioDevices, id: \.internalID) { input in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(input.displayName).lineLimit(1)
            Spacer()
            channelToggle(input, target: .landscape, title: "Landscape")
            channelToggle(input, target: .portrait, title: "Portrait")
            Toggle(
              "Monitor",
              isOn: Binding(
                get: {
                  stateService.localStateURL.map {
                    appletData.state(for: $0).monitorAudioInputDeviceInternalIDs.contains(
                      input.internalID)
                  } ?? false
                },
                set: { enabled in
                  guard let url = stateService.localStateURL else { return }
                  appletData.updateState(for: url) {
                    if enabled {
                      $0.monitorAudioInputDeviceInternalIDs.insert(input.internalID)
                    } else {
                      $0.monitorAudioInputDeviceInternalIDs.remove(input.internalID)
                    }
                  }
                  runtimeActions()?.synchronizeAudioMonitor()
                })
            )
            .disabled(stateService.localStateURL == nil)
            .accessibilityLabel("Monitor " + input.displayName)
          }
          .toggleStyle(.checkbox)
          AudioChannelControl(
            value: Binding(
              get: {
                stateService.workspacePreferences.audioChannelGainsDecibels[input.internalID]?
                  .double ?? 0
              },
              set: { _ = setAudioChannelGain($0, forAudioInputDeviceInternalID: input.internalID) }),
            peakProvider: { peakMeter.peak(for: "v4-\(input.internalID)") },
            title: input.displayName + " Gain"
          )
        }
      }
      if let message = stateService.outputFailureMessage {
        Text(message).foregroundStyle(.red)
      }
      Divider()
    }
  }

  private func channelToggle(
    _ input: Ldtx_Workspace_V4_AudioInputDevice, target: WorkspaceCanvasTarget, title: String
  ) -> some View {
    let programID = appletData.selectedProgram(
      in: stateService.workspaceDefinition, for: stateService.localStateURL)?.internalID
    return Toggle(
      title,
      isOn: Binding(
        get: {
          guard let programID else { return true }
          return stateService.workspacePreferences[keyPath: target.preferences][programID]?
            .audioChannelMuted[input.internalID] != true
        },
        set: { enabled in
          guard let programID,
            stateService.workspaceDefinition.programs.contains(where: { $0.internalID == programID }
            )
          else { return }
          stateService.editWorkspace(undoManager: undoManager) { workspace in
            workspace.preferences[keyPath: target.preferences][programID, default: .init()]
              .audioChannelMuted[input.internalID] = !enabled
          }
        })
    )
    .disabled(programID == nil)
    .accessibilityLabel(title + " " + input.displayName)
  }

  @discardableResult
  func setAudioChannelGain(_ decibels: Double, forAudioInputDeviceInternalID id: Int64) -> Bool {
    guard stateService.workspaceDefinition.audioDevices.contains(where: { $0.internalID == id })
    else {
      reportError(WorkspaceSelectionError(message: "The audio device is no longer available."))
      return false
    }
    do {
      try stateService.editWorkspace(undoManager: undoManager) { workspace in
        workspace.preferences.audioChannelGainsDecibels[id] =
          try Rational32DecibelEncoding.encode(decibels)
      }
      return true
    } catch {
      reportError(error)
      return false
    }
  }
}
