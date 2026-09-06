// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI
import UniformTypeIdentifiers

struct InputDevicesSidebarSection: View {
  @Binding var inputDevices: [WorkspaceInputDeviceRecord]
  @Binding var selectedSidebarItem: WorkspaceSidebarItem?
  let windowState: WorkspaceWindowState
  @State private var draggedName: String?
  let beginAddingDevice: () -> Void

  var body: some View {
    Section(
      content: {
        if inputDevices.isEmpty { Text("No input devices").foregroundStyle(.secondary) }
        ForEach(inputDevices) { device in
          inputDeviceRow(device)
        }
      },
      header: {
        WorkspaceSidebarSectionHeader(
          title: "Input Devices", accessibilityIdentifier: "addWorkspaceInputDeviceButton",
          isAddEnabled: isInputDeviceEditable, add: beginAddingDevice
        )

      }
    )

  }

  @ViewBuilder
  private func inputDeviceRow(_ device: WorkspaceInputDeviceRecord) -> some View {
    let row = WorkspaceResourceSidebarRow(
      name: device.name,
      systemImage: inputDeviceSystemImage(device),
      isDimmed: !isInputDeviceEditable,
      isStrikethrough: false,
      isSelectionEnabled: isInputDeviceEditable,
      select: { selectedSidebarItem = .inputDevice(device.name) }
    )
    if isInputDeviceEditable {
      row
        .tag(WorkspaceSidebarItem.inputDevice(device.name))
        .onDrag {
          draggedName = device.name
          return NSItemProvider(object: device.name as NSString)
        }
        .onDrop(
          of: [UTType.text],
          delegate: InputDeviceDropDelegate(
            destinationName: device.name, inputDevices: $inputDevices,
            draggedName: $draggedName, isEnabled: true
          ))
    } else {
      row
    }
  }

  private var isInputDeviceEditable: Bool {
    windowState.mode == .edit && !windowState.isOperationLocked
  }

  private func inputDeviceSystemImage(
    _ device: WorkspaceInputDeviceRecord
  ) -> String {
    switch device.kind {
    case .video: "video"
    case .audio: "waveform"
    case .unspecified: "questionmark.square.dashed"
    }
  }
}

struct AddInputDeviceDialog: View {
  @Binding var kind: WorkspaceInputDeviceKind
  @Binding var physicalDeviceID: String?
  @Binding var nameLabel: String
  let isNameAvailable: Bool
  let cameras: [InputPhysicalDeviceOption]
  let audioDevices: [InputPhysicalDeviceOption]
  let submit: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Add Input Device").font(.title2).bold()
      VStack(alignment: .leading, spacing: 2) {
        ForEach(cameras) { device in
          deviceRow(device, isAudio: false)
        }
        ForEach(audioDevices) { device in
          deviceRow(device, isAudio: true)
        }
        if cameras.isEmpty && audioDevices.isEmpty {
          Text("No input devices available").foregroundStyle(.secondary)
        }
      }
      .padding(4)
      .background(.background, in: RoundedRectangle(cornerRadius: 8))
      .accessibilityLabel("Device")
      .accessibilityIdentifier("addInputPhysicalDeviceList")

      Form {
        TextField("Name", text: $nameLabel, prompt: Text(selectedDeviceName))
          .accessibilityIdentifier("addInputDeviceNameField")
        if !isNameAvailable {
          Text("This name is already in use.")
            .foregroundStyle(.red)
        }
      }
      .formStyle(.grouped)

      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: cancel)
        Button("Add", action: submit)
          .keyboardShortcut(.defaultAction)
          .disabled(
            selectedDeviceName.isEmpty || !isNameAvailable
              || (nameLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && selectedDeviceName.isEmpty)
          )
      }
    }
    .padding(24)
    .frame(width: 420)
  }

  private func deviceRow(_ device: InputPhysicalDeviceOption, isAudio: Bool) -> some View {
    let isSelected = physicalDeviceID == device.id && (kind == .audio) == isAudio
    return Button {
      kind = isAudio ? .audio : .video
      physicalDeviceID = device.id
    } label: {
      Label(device.name, systemImage: isAudio ? "waveform" : "video")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(isSelected ? Color.white : Color.primary)
    .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private var selectedDeviceName: String {
    availableDevices.first { $0.id == physicalDeviceID }?.name ?? ""
  }

  private var availableDevices: [InputPhysicalDeviceOption] {
    kind == .audio ? audioDevices : cameras
  }
}

struct WorkspaceResourceSidebarRow: View {
  let name: String
  let systemImage: String
  var isDimmed = false
  var isStrikethrough = false
  let isSelectionEnabled: Bool
  let select: () -> Void
  var leadingAction: (() -> Void)?
  var leadingActionLabel: String?
  var leadingActionIdentifier: String?
  var leadingActionHelp: String?

  var body: some View {
    HStack(spacing: 8) {
      if let leadingAction {
        Button(action: leadingAction) {
          resourceIcon
        }
        .buttonStyle(.plain)
        .accessibilityLabel(leadingActionLabel ?? name)
        .accessibilityIdentifier(leadingActionIdentifier ?? "")
        .help(leadingActionHelp ?? "")

        selectionButton
      } else {
        Button(action: select) {
          HStack(spacing: 8) {
            resourceIcon
            resourceName
            Spacer(minLength: 8)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelectionEnabled)
      }
    }
    .foregroundStyle(isDimmed ? .secondary : .primary)
    .opacity(isDimmed ? 0.6 : 1)
  }

  private var selectionButton: some View {
    Button(action: select) {
      HStack {
        resourceName
        Spacer(minLength: 8)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isSelectionEnabled)
  }

  private var resourceName: some View {
    Text(name)
      .lineLimit(1)
      .strikethrough(isStrikethrough)
  }

  private var resourceIcon: some View {
    Image(systemName: systemImage)
      .frame(width: 16)
      .contentShape(Rectangle())
  }
}

private struct InputDeviceDropDelegate: DropDelegate {
  let destinationName: String
  @Binding var inputDevices: [WorkspaceInputDeviceRecord]
  @Binding var draggedName: String?
  let isEnabled: Bool
  func dropEntered(info _: DropInfo) {
    guard isEnabled, let draggedName, draggedName != destinationName,
      let source = inputDevices.firstIndex(where: { $0.name == draggedName }),
      let destination = inputDevices.firstIndex(where: { $0.name == destinationName })
    else { return }
    inputDevices.move(
      fromOffsets: IndexSet(integer: source),
      toOffset: source < destination ? destination + 1 : destination)
  }
  func performDrop(info _: DropInfo) -> Bool {
    draggedName = nil
    return isEnabled
  }
  func dropUpdated(info _: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}
