// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXDeviceRegistry
import LDTXWorkspaceAppletInterface
import SwiftUI

struct WorkspacePhysicalDeviceField: View {
  @Environment(\.workspaceDispatcher) private var dispatcher
  let title: String
  let internalID: UInt64
  let isAudio: Bool
  let uiState: WorkspaceUIState
  let appletData: WorkspaceAppletData
  let deviceRegistry: DeviceRegistryService
  var isEditable = true

  private var options: [WorkspaceSelectionOption<WorkspacePhysicalDeviceID>] {
    if isAudio {
      return deviceRegistry.audioInputDevices.map {
        .init(id: .coreAudioDevice(uid: $0.id), name: $0.name)
      }
    }
    return deviceRegistry.cameras.map {
      .init(id: .avCaptureDevice(uniqueID: $0.id), name: $0.name)
    }
  }

  var body: some View {
    WorkspaceSelectionField(
      title: title, current: appletData.physicalDeviceID(for: internalID), options: options,
      loaded: deviceRegistry.hasRefreshed,
      loadError: isAudio ? deviceRegistry.errorMessage : nil,
      clearTitle: "Remove Assignment", isEditable: isEditable && !uiState.isOutputActive,
      refresh: { deviceRegistry.refresh() },
      commit: { proposed in
        try applySelection(proposed)
        dispatcher?.synchronizeCaptureInputs(
          availableCameraIDs: Set(deviceRegistry.cameras.map(\.id))
        ) { _ in }
        dispatcher?.synchronizeAudioMonitor()
      }
    )
    .onAppear { if !deviceRegistry.hasRefreshed { deviceRegistry.refresh() } }
  }

  func applySelection(_ proposed: WorkspacePhysicalDeviceID?) throws {
    guard isEditable, !uiState.isOutputActive else {
      throw WorkspaceSelectionError(message: "Stop output before changing an assignment.")
    }
    guard
      uiState.definition.inputDevices.contains(where: {
        if isAudio, case .audioDevice(let value) = $0.definition {
          return value.internalID == internalID
        }
        if !isAudio, case .videoDevice(let value) = $0.definition {
          return value.internalID == internalID
        }
        return false
      })
    else { throw WorkspaceSelectionError(message: "This input no longer exists.") }
    if proposed != nil { deviceRegistry.refresh() }
    if proposed != nil, isAudio, let error = deviceRegistry.errorMessage {
      throw WorkspaceSelectionError(message: error)
    }
    guard proposed == nil || options.contains(where: { $0.id == proposed }) else {
      throw WorkspaceSelectionError(message: "The selected device is unavailable.")
    }
    appletData.setPhysicalDeviceID(proposed, for: internalID)
  }

}
