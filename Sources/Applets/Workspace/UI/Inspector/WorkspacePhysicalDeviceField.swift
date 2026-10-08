// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXDeviceRegistry
import LDTXWorkspaceAppletInterface
import SwiftUI

struct WorkspacePhysicalDeviceField: View {
  let title: String
  let internalID: UInt64
  let isAudio: Bool
  let storeService: WorkspaceStoreService
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
      clearTitle: "Remove Assignment", isEditable: isEditable && !storeService.isOutputActive,
      refresh: { deviceRegistry.refresh() },
      reportError: { storeService.reportError($0) },
      commit: { proposed in
        try applySelection(proposed)
        storeService.synchronizeCaptureInputs(
          availableCameraIDs: Set(deviceRegistry.cameras.map(\.id))
        ) { _ in }
        storeService.synchronizeAudioMonitor()
      }
    )
    .onAppear { if !deviceRegistry.hasRefreshed { deviceRegistry.refresh() } }
  }

  func applySelection(_ proposed: WorkspacePhysicalDeviceID?) throws {
    guard isEditable, !storeService.isOutputActive else {
      throw WorkspaceSelectionError(message: "Stop output before changing an assignment.")
    }
    let exists =
      isAudio
      ? storeService.definition.audioDevices.contains { $0.internalID == internalID }
      : storeService.definition.videoComponents.contains {
        guard case .vfxSource(let source) = $0.videoComponent else { return false }
        return source.internalID == internalID
      }
    guard exists else { throw WorkspaceSelectionError(message: "This resource no longer exists.") }
    if proposed != nil { deviceRegistry.refresh(reportErrors: false) }
    if proposed != nil, isAudio, let error = deviceRegistry.error {
      throw error
    }
    guard proposed == nil || options.contains(where: { $0.id == proposed }) else {
      throw WorkspaceSelectionError(message: "The selected device is unavailable.")
    }
    appletData.setPhysicalDeviceID(proposed, for: internalID)
  }

}
