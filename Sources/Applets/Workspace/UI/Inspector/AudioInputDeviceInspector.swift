// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXWorkspaceAppletInterface
import SwiftUI

struct AudioInputDeviceInspector: View {
  @Environment(\.documentReference) private var documentReference
  private var workspaceURL: URL? {
    guard let document = documentReference?.document else { return nil }
    return document.fileURL ?? uiState.localStateURL
  }
  @Environment(\.workspaceDispatcher) private var workspaceDispatcher
  let uiState: WorkspaceUIState
  let internalID: UInt64
  let deviceRegistry: DeviceRegistryService
  @Bindable var appletData: WorkspaceAppletData

  var body: some View {
    Form {
      formContent
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private var formContent: some View {
    if device != nil {
      Section("Audio Input Device") {
        TextField("Name", text: nameBinding)
          .disabled(uiState.isOutputActive)
        if workspaceURL != nil {
          Picker(
            "Physical Device",
            selection: physicalDeviceBinding
          ) {
            Text("No Audio Device").tag(Optional<WorkspacePhysicalDeviceID>.none)
            ForEach(deviceRegistry.audioInputDevices, id: \.id) { source in
              Text(source.name).tag(
                Optional(WorkspacePhysicalDeviceID.coreAudioDevice(uid: source.id)))
            }
          }
          .disabled(uiState.isOutputActive)
        }
      }
    } else {
      missingItem
    }

  }

  private var device: Ldtx_Workspace_V4_AudioInputDevice? {
    uiState.definition.inputDevices.compactMap { wrapper -> Ldtx_Workspace_V4_AudioInputDevice? in
      guard case .audioDevice(let device) = wrapper.definition,
        device.internalID == internalID
      else { return nil }
      return device
    }.first
  }

  private var nameBinding: Binding<String> {
    Binding(
      get: { device?.displayName ?? "" },
      set: { name in
        updateInputDevice { wrapper in
          guard case .audioDevice(var value) = wrapper.definition else { return }
          value.displayName = name
          wrapper.definition = .audioDevice(value)
        }
      }
    )
  }

  private var physicalDeviceBinding: Binding<WorkspacePhysicalDeviceID?> {
    Binding(
      get: {
        guard let url = workspaceURL else { return nil }
        guard
          case .coreAudioDevice? = appletData.state(for: url)
            .physicalDeviceIDsByInputDeviceInternalID[internalID]
        else { return nil }
        return appletData.state(for: url).physicalDeviceIDsByInputDeviceInternalID[internalID]
      },
      set: { identifier in
        guard let url = workspaceURL else { return }
        appletData.updateState(for: url) {
          $0.physicalDeviceIDsByInputDeviceInternalID[internalID] = identifier
        }
        workspaceDispatcher?.updateProgramRuntimes()
        workspaceDispatcher?.synchronizeAudioMonitor()
      }
    )
  }

  private var missingItem: some View {
    Section("Audio Input Device") {
      Text("This item is no longer present in the Workspace.")
        .foregroundStyle(.secondary)
    }
  }
  private func updateInputDevice(_ mutation: (inout Ldtx_Workspace_V4_InputDeviceWrapper) -> Void) {
    var definition = uiState.definition
    guard
      let index = definition.inputDevices.firstIndex(where: { wrapper in
        switch wrapper.id {
        case .audioDevice(let id), .videoDevice(let id): id == internalID
        case .invalid: false
        }
      })
    else { return }
    mutation(&definition.inputDevices[index])
    uiState.definition = definition
  }

}
