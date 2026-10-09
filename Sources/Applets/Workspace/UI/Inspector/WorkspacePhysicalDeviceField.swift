// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXDeviceRegistry
import LDTXWorkspaceAppletModel
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
    VStack(alignment: .leading) {
      Picker(
        title,
        selection: Binding(
          get: { appletData.physicalDeviceID(for: internalID) },
          set: { proposed in
            do {
              try applySelection(proposed)
              storeService.synchronizeCaptureInputs(
                availableCameraIDs: Set(deviceRegistry.cameras.map(\.id))
              ) { _ in }
              storeService.synchronizeAudioMonitor()
            } catch { storeService.reportError(error) }
          })
      ) {
        Text("Unassigned").tag(WorkspacePhysicalDeviceID?.none)
        ForEach(options) { option in
          Text(option.name).tag(Optional(option.id))
        }
        if let selected = appletData.physicalDeviceID(for: internalID),
          !options.contains(where: { $0.id == selected })
        {
          Text(deviceRegistry.hasRefreshed ? "Unavailable" : "Checking…")
            .tag(Optional(selected))
        }
      }
      .pickerStyle(.menu)
      .disabled(!isEditable || storeService.isOutputActive)
      .onAppear { if !deviceRegistry.hasRefreshed { deviceRegistry.refresh() } }
      if isAudio, let message = deviceRegistry.errorMessage {
        Text(message).font(.caption).foregroundStyle(.red)
      }
    }
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
