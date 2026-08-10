// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI

struct VideoComponentsSidebarSection: View {
  @Binding var videoComponents: [WorkspaceVideoComponentRecord]
  @Binding var selectedSidebarItem: WorkspaceSidebarItem?
  let inputDevices: [WorkspaceInputDeviceRecord]
  let visions: [WorkspaceVisionDefinition]
  let windowState: WorkspaceWindowState
  @State private var isShowingAddDialog = false
  @State private var proposedInputDeviceID: String?
  @State private var proposedKind = ProgramComponentDefinition.inputCameraDevice
  @State private var proposedNameLabel = "Video Component"
  @State private var addDialogWindowState: WorkspaceWindowState?

  var body: some View {
    Section {
      if videoComponents.isEmpty {
        Text("No video components").foregroundStyle(.secondary)
      }
      ForEach(videoComponents) { component in
        videoComponentRow(component)
      }
    } header: {
      WorkspaceSidebarSectionHeader(
        title: "Video Components",
        accessibilityIdentifier: "addWorkspaceVideoComponentButton",
        isAddEnabled: isVideoComponentEditable,
        add: beginAddingVideoComponent
      )
    }
    .sheet(
      isPresented: $isShowingAddDialog,
      onDismiss: {
        addDialogWindowState = nil
      }
    ) {
      AddVideoComponentDialog(
        kind: $proposedKind,
        inputDeviceID: $proposedInputDeviceID,
        nameLabel: $proposedNameLabel,
        numberedName: proposedNumberedName,
        inputDevices: videoInputDevices,
        submit: addVideoComponent,
        cancel: { isShowingAddDialog = false }
      )
    }
  }

  @ViewBuilder
  private func videoComponentRow(_ component: WorkspaceVideoComponentRecord) -> some View {
    let row = WorkspaceResourceSidebarRow(
      name: component.name,
      systemImage: component.component.definition.sidebarSystemImage,
      isDimmed: !isVideoComponentEditable(component),
      isSelectionEnabled: isVideoComponentEditable(component),
      select: { selectedSidebarItem = .videoComponent(component.id) }
    )
    if isVideoComponentEditable(component) {
      row.tag(WorkspaceSidebarItem.videoComponent(component.id))
    } else {
      row
    }
  }

  private func beginAddingVideoComponent() {
    guard isVideoComponentEditable else { return }
    addDialogWindowState = windowState
    proposedInputDeviceID = videoInputDevices.first?.id
    proposedKind = .inputCameraDevice
    proposedNameLabel = proposedKind.defaultName
    isShowingAddDialog = true
  }

  private var isVideoComponentEditable: Bool {
    windowState.mode == .edit && !windowState.isOperationLocked
  }

  private func isVideoComponentEditable(_ component: WorkspaceVideoComponentRecord) -> Bool {
    guard !windowState.isOperationLocked else { return false }
    return windowState.mode == .edit || component.component.definition.isFill
  }

  private func addVideoComponent() {
    guard addDialogWindowState == windowState, isVideoComponentEditable else {
      isShowingAddDialog = false
      return
    }
    if proposedKind.usesInputCameraDevice {
      guard let proposedInputDeviceID,
        videoInputDevices.contains(where: { $0.id == proposedInputDeviceID })
      else { return }
    }
    let label = proposedNameLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { return }
    let name = WorkspaceResourceNameValidator.nextNumberedName(
      label: label,
      inputDevices: inputDevices,
      videoComponents: videoComponents,
      visions: visions
    )
    var component = ProgramComponent.defaultComponent(for: proposedKind)
    if case .inputCameraDevice(var payload) = component {
      payload.inputDeviceID = proposedInputDeviceID
      component = .inputCameraDevice(payload)
    }
    videoComponents.append(WorkspaceVideoComponentRecord(name: name, component: component))
    selectedSidebarItem = .videoComponent(name)
    isShowingAddDialog = false
  }

  private var videoInputDevices: [WorkspaceInputDeviceRecord] {
    inputDevices.filter { $0.kind == .video }
  }

  private var proposedNumberedName: String {
    WorkspaceResourceNameValidator.nextNumberedName(
      label: proposedNameLabel,
      inputDevices: inputDevices,
      videoComponents: videoComponents,
      visions: visions
    )
  }
}

private struct AddVideoComponentDialog: View {
  @Binding var kind: ProgramComponentDefinition
  @Binding var inputDeviceID: String?
  @Binding var nameLabel: String
  let numberedName: String
  let inputDevices: [WorkspaceInputDeviceRecord]
  let submit: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Add Video Component").font(.title2).bold()
      Form {
        Picker("Kind", selection: $kind) {
          ForEach(ProgramComponentDefinition.renderableCases) { kind in
            Text(kind.displayName).tag(kind)
          }
        }
        .accessibilityIdentifier("addVideoComponentKindPicker")
        if kind.usesInputCameraDevice {
          Picker("Device", selection: $inputDeviceID) {
            if inputDevices.isEmpty {
              Text("No video input devices").tag(String?.none)
            }
            ForEach(inputDevices) { device in
              Text(device.name).tag(Optional(device.id))
            }
          }
          .accessibilityIdentifier("addVideoComponentDevicePicker")
        }
        TextField("Name", text: $nameLabel, prompt: Text("Video Component"))
          .accessibilityIdentifier("addVideoComponentNameField")
        LabeledContent("Saved Name", value: numberedName)
      }
      .formStyle(.grouped)

      if kind.usesInputCameraDevice && inputDevices.isEmpty {
        Text("Add a Video Input Device before creating a Video Component.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: cancel)
        Button("Add", action: submit)
          .keyboardShortcut(.defaultAction)
          .disabled(
            (kind.usesInputCameraDevice && inputDeviceID == nil)
              || nameLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
      }
    }
    .padding(24)
    .frame(width: 420)
    .onChange(of: kind) { _, newKind in
      nameLabel = newKind.defaultName
    }
  }
}

extension ProgramComponentDefinition {
  fileprivate var defaultName: String {
    switch self {
    case .inputCameraDevice: "Video Component"
    case .fillSolidColor: "Solid Color"
    case .fillLinearGradient: "Linear Gradient"
    case .fillRadialGradient: "Radial Gradient"
    case .fillConicGradient: "Conic Gradient"
    case .clock: "Clock"
    case .testPattern: "Test Pattern"
    }
  }

  fileprivate var sidebarSystemImage: String {
    switch self {
    case .inputCameraDevice: "play.rectangle"
    case .fillSolidColor: "square"
    case .fillLinearGradient: "circle.lefthalf.filled"
    case .fillRadialGradient: "circle.righthalf.filled"
    case .fillConicGradient: "circle.bottomhalf.filled"
    case .clock: "clock"
    case .testPattern: "checkerboard.rectangle"
    }
  }
}
