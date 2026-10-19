// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXDeviceRegistry
import LDTXWorkspaceAppletModel
import SwiftUI

struct WorkspacePhysicalDeviceField: View {
  @Environment(\.workspaceReportError) private var reportError
  let title: String
  let internalID: Int64
  let isAudio: Bool
  let stateService: WorkspaceDocument
  let appletData: WorkspaceAppletData
  let deviceRegistry: DeviceRegistryService
  var isEditable = true

  var runtimeActions: () -> (any WorkspaceRuntimeActions)? = { nil }
  @State private var isShowingPicker = false
  @State private var draft: WorkspacePhysicalDeviceID?

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
      LabeledContent(title) {
        HStack {
          if let selected = appletData.physicalDeviceID(for: internalID) {
            Text(
              options.first { $0.id == selected }?.name
                ?? String(localized: "Unavailable"))
          } else {
            Text("Unassigned")
          }
          Button("Choose…") {
            deviceRegistry.refresh()
            let current = appletData.physicalDeviceID(for: internalID)
            draft = options.contains { $0.id == current } ? current : nil
            isShowingPicker = true
          }
        }
      }
      .disabled(!isEditable || stateService.isOutputActive)
      .onAppear { if !deviceRegistry.hasRefreshed { deviceRegistry.refresh() } }
      if isAudio, let message = deviceRegistry.errorMessage {
        Text(message).font(.caption).foregroundStyle(.red)
      }
    }
    .sheet(isPresented: $isShowingPicker) {
      VStack {
        Form {
          Picker(title, selection: $draft) {
            Text("Unassigned").tag(WorkspacePhysicalDeviceID?.none)
            ForEach(options) { Text($0.name).tag(Optional($0.id)) }
          }
          .disabled(!isEditable || stateService.isOutputActive)
        }
        HStack {
          Spacer()
          Button("Cancel", role: .cancel) { isShowingPicker = false }
            .keyboardShortcut(.cancelAction)
          Button("Choose") {
            do {
              try applySelection(draft)
              runtimeActions()?.synchronizeCaptureInputs(
                availableCameraIDs: Set(deviceRegistry.cameras.map(\.id))
              ) { _ in }
              runtimeActions()?.synchronizeAudioMonitor()
              isShowingPicker = false
            } catch { reportError(error) }
          }
          .disabled(!isEditable || stateService.isOutputActive)
          .keyboardShortcut(.defaultAction)
        }
      }
      .padding()
      .frame(width: 400)
      .onChange(of: options.map(\.id)) { _, ids in
        draft = WorkspaceSelectionRules.reconciled(draft, availableIDs: ids)
      }
    }
  }

  func applySelection(_ proposed: WorkspacePhysicalDeviceID?) throws {
    guard isEditable, !stateService.isOutputActive else {
      throw WorkspaceSelectionError(message: "Stop output before changing an assignment.")
    }
    let exists =
      isAudio
      ? stateService.workspaceDefinition.audioDevices.contains { $0.internalID == internalID }
      : stateService.workspaceDefinition.videoComponents.contains {
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
