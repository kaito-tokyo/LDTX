// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

struct WorkspaceAddResourceSheet: View {
  let sheet: WorkspaceAddSheet
  @Binding var draft: WorkspaceAddDraft
  let devices: [WorkspaceAddDeviceOption]
  let videoComponents: [Ldtx_Workspace_V4_VideoComponentWrapper]
  let validationMessage: String?
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
            if devices.isEmpty { Text("No audio devices available").foregroundStyle(.secondary) }
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
        if sheet == .vision {
          Text("Video Component")
          ForEach(componentOptions) { input in
            Button {
              draft.videoComponentID = input.id
            } label: {
              HStack {
                Text(input.name)
                Spacer()
                if draft.videoComponentID == input.id { Image(systemName: "checkmark") }
              }
            }.buttonStyle(.plain)
          }
          if videoComponents.isEmpty { Text("No video components").foregroundStyle(.secondary) }
        }
        TextField("Name", text: $draft.name, prompt: Text(selectedDeviceName))
          .focused($nameFocused)
          .accessibilityIdentifier("addResourceNameField")
          .onSubmit { if validationMessage == nil { submit() } }
      }
      .formStyle(.grouped)
      if sheet == .vision {
        Text("Recognize text locally with Apple Vision.").font(.caption).foregroundStyle(.secondary)
      }
      if let message = validationMessage {
        Text(message).font(.caption).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
        Button("Add", action: submit).keyboardShortcut(.defaultAction)
          .disabled(validationMessage != nil)
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
    .onChange(of: componentOptions.map(\.id)) { _, ids in
      draft.videoComponentID = WorkspaceSelectionRules.reconciled(
        draft.videoComponentID, availableIDs: ids)
    }
    .onChange(of: draft.componentKind) { _, kind in draft.name = kind.rawValue }
  }

  private var componentOptions: [WorkspaceSelectionOption<UInt64>] {
    videoComponents.compactMap {
      guard let id = $0.internalID,
        let name = $0.displayName
      else { return nil }
      return .init(id: id, name: name)
    }
  }

  private var selectedDeviceName: String {
    guard sheet == .device else { return "" }
    return devices.first { $0.id == draft.physicalDeviceID }?.name ?? ""
  }
}
