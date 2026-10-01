// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXDeviceRegistry
import LDTXWorkspaceAppletInterface
import SwiftUI

struct VideoInputDeviceInspector: View {
  @Environment(\.workspaceDispatcher) private var workspaceDispatcher
  let uiState: WorkspaceUIState
  let internalID: UInt64
  let workspaceURL: URL?
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
      Section("Video Input Device") {
        TextField("Name", text: nameBinding)
          .disabled(uiState.isOutputActive)
        if let workspaceURL {
          Picker(
            "Physical Device",
            selection: physicalDeviceBinding(url: workspaceURL)
          ) {
            Text("No Camera").tag(Optional<WorkspacePhysicalDeviceID>.none)
            ForEach(deviceRegistry.cameras, id: \.id) { source in
              Text(source.name).tag(
                Optional(WorkspacePhysicalDeviceID.avCaptureDevice(uniqueID: source.id)))
            }
          }
          .disabled(uiState.isOutputActive)
        }
      }
    } else {
      missingItem
    }

  }

  private var device: Ldtx_Workspace_V4_VideoInputDevice? {
    uiState.definition.inputDevices.compactMap { wrapper -> Ldtx_Workspace_V4_VideoInputDevice? in
      guard case .videoDevice(let device) = wrapper.definition,
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
          guard case .videoDevice(var value) = wrapper.definition else { return }
          value.displayName = name
          wrapper.definition = .videoDevice(value)
        }
      }
    )
  }

  private func physicalDeviceBinding(
    url: URL
  ) -> Binding<WorkspacePhysicalDeviceID?> {
    Binding(
      get: {
        guard
          case .avCaptureDevice? = appletData.state(for: url)
            .physicalDeviceIDsByInputDeviceInternalID[internalID]
        else { return nil }
        return appletData.state(for: url).physicalDeviceIDsByInputDeviceInternalID[internalID]
      },
      set: { identifier in
        appletData.updateState(for: url) {
          $0.physicalDeviceIDsByInputDeviceInternalID[internalID] = identifier
        }
        workspaceDispatcher?.updateProgramRuntimes()
        workspaceDispatcher?.synchronizeCaptureInputs(
          availableCameraIDs: Set(deviceRegistry.cameras.map(\.id))
        ) { _ in }
      }
    )
  }

  private var missingItem: some View {
    Section("Video Input Device") {
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
