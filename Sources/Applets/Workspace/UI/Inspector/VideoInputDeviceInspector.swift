// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

struct VideoInputDeviceInspector: View {
  let uiState: WorkspaceUIState
  let internalID: UInt64
  let windowRuntime: (any WorkspaceWindowRuntimeProtocol)?
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
        if let windowRuntime, let workspaceURL = windowRuntime.url {
          Picker(
            "Physical Device",
            selection: physicalDeviceBinding(url: workspaceURL)
          ) {
            Text("No Camera").tag("")
            ForEach(windowRuntime.availableCaptureDevices().cameras, id: \.id) { source in
              Text(source.name).tag(source.id)
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
  ) -> Binding<String> {
    Binding(
      get: {
        appletData.state(for: url).videoInputDevicePhysicalIDs[internalID] ?? ""
      },
      set: { identifier in
        guard let windowRuntime else { return }
        windowRuntime.setPhysicalVideoDeviceID(
          identifier.isEmpty ? nil : identifier, for: internalID)
        windowRuntime.synchronizeCaptureInputs(
          availableCameraIDs: Set(windowRuntime.availableCaptureDevices().cameras.map(\.id))
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
