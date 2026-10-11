// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXProtos
import SwiftUI

struct AudioInputDeviceInspector: View {
  weak var document: NSDocument? = nil
  let storeService: WorkspaceStoreService
  let internalID: Int64
  let deviceRegistry: DeviceRegistryService
  @Bindable var appletData: WorkspaceAppletData

  var runtimeActions: () -> (any WorkspaceRuntimeActions)? = { nil }

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
          .disabled(storeService.isOutputActive)
        if document != nil {
          WorkspacePhysicalDeviceField(
            title: "Physical Device", internalID: internalID, isAudio: true,
            storeService: storeService, appletData: appletData, deviceRegistry: deviceRegistry,
            runtimeActions: runtimeActions)
        }
      }
    } else {
      missingItem
    }

  }

  private var device: Ldtx_Workspace_V4_AudioInputDevice? {
    storeService.workspaceDefinition.audioDevices.first { $0.internalID == internalID }
  }

  private var nameBinding: Binding<String> {
    Binding(
      get: { device?.displayName ?? "" },
      set: { name in
        updateInputDevice { wrapper in
          wrapper.displayName = name
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
  private func updateInputDevice(_ mutation: (inout Ldtx_Workspace_V4_AudioInputDevice) -> Void) {
    var definition = storeService.workspaceDefinition
    guard
      let index = definition.audioDevices.firstIndex(where: { $0.internalID == internalID })
    else { return }
    mutation(&definition.audioDevices[index])
    storeService.workspaceDefinition = definition
  }

}
