// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletData
import LDTXWorkspaceAppletInterface
import SwiftUI

struct VideoInputDeviceInspector: View {
  let uiState: WorkspaceUIState
  let internalID: UInt64
  let session: (any WorkspaceSessionProtocol)?
  let recordingSession: (any WorkspaceRecordingSessionProtocol)?
  let deviceMappingAppletData: WorkspaceDeviceAppletData?

  var body: some View {
    if device != nil {
      Section("Video Input Device") {
        TextField("Name", text: nameBinding)
          .disabled(recordingSession?.isRecording ?? false)
        if let session, let deviceMappingAppletData, let workspaceURL = session.url {
          Picker(
            "Physical Device",
            selection: physicalDeviceBinding(data: deviceMappingAppletData, url: workspaceURL)
          ) {
            Text("No Camera").tag("")
            ForEach(session.availableCaptureDevices().cameras, id: \.id) { source in
              Text(source.name).tag(source.id)
            }
          }
          .disabled(recordingSession?.isRecording ?? false)
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
    data: WorkspaceDeviceAppletData, url: URL
  ) -> Binding<String> {
    Binding(
      get: { data.videoDeviceID(for: internalID, workspaceURL: url) ?? "" },
      set: { identifier in
        data.setVideoDeviceID(
          identifier.isEmpty ? nil : identifier, for: internalID, workspaceURL: url)
        guard let session else { return }
        session.synchronizeCaptureInputs(
          availableCameraIDs: Set(session.availableCaptureDevices().cameras.map(\.id))
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
