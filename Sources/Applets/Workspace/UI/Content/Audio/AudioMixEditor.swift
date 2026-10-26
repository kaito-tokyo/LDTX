// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import LDTXWorkspaceAppletInterface
import LDTXWorkspaceAppletModel
import SwiftUI

struct AudioMixEditor: View {
  @Environment(\.undoManager) private var undoManager
  let stateService: WorkspaceDocument
  let appletData: WorkspaceAppletData
  let peakMeter: any ProgramAudioPeakMeterPresenting
  let reportError: (Error) -> Void
  var runtimeActions: () -> (any WorkspaceRuntimeActions)? = { nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Audio Mix").fontWeight(.semibold)
      ForEach(stateService.workspaceDefinition.audioDevices, id: \.internalID) { input in
        if let id = input.internalID, let name = input.displayName {
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(name).lineLimit(1)
              Spacer()
              channelToggle(input, target: .landscape, title: "Landscape")
              channelToggle(input, target: .portrait, title: "Portrait")
              Toggle(
                "Monitor",
                isOn: Binding(
                  get: {
                    stateService.localStateURL.map {
                      appletData.state(for: $0).monitorAudioInputDeviceInternalIDs.contains(
                        id)
                    } ?? false
                  },
                  set: { enabled in
                    guard let url = stateService.localStateURL else { return }
                    appletData.updateState(for: url) {
                      if enabled {
                        $0.monitorAudioInputDeviceInternalIDs.insert(id)
                      } else {
                        $0.monitorAudioInputDeviceInternalIDs.remove(id)
                      }
                    }
                    runtimeActions()?.synchronizeAudioMonitor()
                  })
              )
              .disabled(stateService.localStateURL == nil || stateService.isOutputActive)
              .accessibilityLabel("Monitor " + name)
            }
            .toggleStyle(.checkbox)
            AudioChannelControl(
              value: Binding(
                get: {
                  stateService.workspacePreferences.audioChannelGainsDecibels[id]?
                    .double(defaultNumerator: 0, defaultDenominator: 1) ?? 0
                },
                set: { _ = setAudioChannelGain($0, forAudioInputDeviceInternalID: id) }),
              peakProvider: { peakMeter.peak(for: "v4-\(id)") },
              title: name + " Gain"
            )
          }
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
          guard let programID, let id = input.internalID else { return true }
          return stateService.workspacePreferences[keyPath: target.preferences][programID]?
            .audioChannelMuted[id] != true
        },
        set: { enabled in
          guard let programID, let id = input.internalID,
            stateService.workspaceDefinition.programs.contains(where: { $0.internalID == programID }
            )
          else { return }
          stateService.editWorkspace(undoManager: undoManager) { workspace in
            workspace.preferences[keyPath: target.preferences][programID, default: .init()]
              .audioChannelMuted[id] = !enabled
          }
        })
    )
    .disabled(programID == nil)
    .accessibilityLabel(title + " " + (input.displayName ?? ""))
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
