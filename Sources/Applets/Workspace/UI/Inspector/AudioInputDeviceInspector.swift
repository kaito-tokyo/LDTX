// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXWorkspaceAppletInterface
import SwiftUI

struct AudioInputDeviceInspector: View {
  @Environment(\.documentReference) private var documentReference
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
        if documentReference?.document != nil {
          WorkspacePhysicalDeviceField(
            title: "Physical Device", internalID: internalID, isAudio: true,
            uiState: uiState, appletData: appletData, deviceRegistry: deviceRegistry)
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
