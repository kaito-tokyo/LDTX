// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

struct WorkspaceAddResourceSheet: View {
  let sheet: WorkspaceAddSheet
  @Binding var draft: WorkspaceAddDraft
  let devices: [WorkspaceAddDeviceOption]
  let videoInputs: [Ldtx_Workspace_V4_VideoInputDevice]
  let validationMessage: String?
  let errorMessage: String?
  let submit: () -> Void
  let cancel: () -> Void
  var refresh: () -> Void = {}
  var deviceDiscoveryMessage: String? = nil
  @FocusState private var nameFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(sheet.title).font(.title2).bold()
      if sheet == .device {
        Button("Refresh Devices", action: refresh)
        if let deviceDiscoveryMessage {
          Text(deviceDiscoveryMessage).font(.caption).foregroundStyle(.red)
        }
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(devices) { device in
              Button {
                draft.physicalDeviceID = device.id
              } label: {
                Label {
                  Text(device.name)
                } icon: {
                  Image(systemName: device.isAudio ? "waveform" : "video")
                    .frame(width: 20)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .foregroundStyle(draft.physicalDeviceID == device.id ? Color.white : .primary)
              .background(
                draft.physicalDeviceID == device.id ? Color.accentColor : .clear,
                in: RoundedRectangle(cornerRadius: 5)
              )
              .accessibilityAddTraits(draft.physicalDeviceID == device.id ? [.isSelected] : [])
            }
            if devices.isEmpty { Text("No input devices available").foregroundStyle(.secondary) }
          }
        }
        .frame(height: min(240, CGFloat(max(1, devices.count)) * 40))
        .accessibilityIdentifier("addInputPhysicalDeviceList")
      }
      Form {
        if sheet == .videoComponent {
          Picker("Kind", selection: $draft.componentKind) {
            ForEach(WorkspaceAddComponentKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
          }
          .accessibilityIdentifier("addVideoComponentKindPicker")
        }
        if sheet == .vision || (sheet == .videoComponent && draft.componentKind == .vfxSource) {
          Text("Video Input")
          ForEach(videoInputs, id: \.internalID) { input in
            Button {
              draft.videoInputID = input.internalID
            } label: {
              HStack {
                Text(input.displayName)
                Spacer()
                if draft.videoInputID == input.internalID { Image(systemName: "checkmark") }
              }
            }.buttonStyle(.plain)
          }
          if videoInputs.isEmpty { Text("No video input devices").foregroundStyle(.secondary) }
        }
        TextField("Name", text: $draft.name, prompt: Text(selectedDeviceName))
          .focused($nameFocused)
          .accessibilityIdentifier("addResourceNameField")
          .onSubmit { if validationMessage == nil && errorMessage == nil { submit() } }
      }
      .formStyle(.grouped)
      if sheet == .vision {
        Text("Recognize text locally with Apple Vision.").font(.caption).foregroundStyle(.secondary)
      }
      if let message = errorMessage ?? validationMessage {
        Text(message).font(.caption).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
        Button("Add", action: submit).keyboardShortcut(.defaultAction)
          .disabled(validationMessage != nil || errorMessage != nil)
          .accessibilityIdentifier("confirmAddResourceButton")
      }
    }
    .padding(24)
    .frame(width: 420)
    .onAppear { nameFocused = true }
    .onChange(of: devices.map(\.id)) { _, ids in
      draft.physicalDeviceID = WorkspaceSelectionRules.reconciled(
        draft.physicalDeviceID, availableIDs: ids)
    }
    .onChange(of: videoInputs.map(\.internalID)) { _, ids in
      draft.videoInputID = WorkspaceSelectionRules.reconciled(draft.videoInputID, availableIDs: ids)
    }
    .onChange(of: draft.componentKind) { _, kind in draft.name = kind.rawValue }
  }

  private var selectedDeviceName: String {
    guard sheet == .device else { return "" }
    return devices.first { $0.id == draft.physicalDeviceID }?.name ?? ""
  }
}
