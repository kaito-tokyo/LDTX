// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI
import UniformTypeIdentifiers

struct InputDevicesSidebarSection: View {
    @Binding var inputDevices: [WorkspaceInputDeviceRecord]
    @Binding var preferences: ProgramPreferences
    @Binding var selectedSidebarItem: WorkspaceSidebarItem?
    let visions: [WorkspaceVisionDefinition]
    let videoComponents: [WorkspaceVideoComponentRecord]
    let cameras: [InputPhysicalDeviceOption]
    let audioDevices: [InputPhysicalDeviceOption]
    let windowState: WorkspaceWindowState
    @State private var draggedName: String?
    @State private var isShowingAddDialog = false
    @State private var proposedKind = WorkspaceInputDeviceKind.video
    @State private var proposedPhysicalDeviceID: String?
    @State private var proposedNameLabel = "Video Capture"
    @State private var addDialogWindowState: WorkspaceWindowState?

    var body: some View {
        Section {
            if inputDevices.isEmpty { Text("No input devices").foregroundStyle(.secondary) }
            ForEach(inputDevices) { device in
                inputDeviceRow(device)
            }
        } header: {
            WorkspaceSidebarSectionHeader(
                title: "Input Devices", accessibilityIdentifier: "addWorkspaceInputDeviceButton",
                isAddEnabled: isInputDeviceEditable, add: beginAddingDevice
            )
        }
        .sheet(isPresented: $isShowingAddDialog, onDismiss: {
            addDialogWindowState = nil
        }) {
            AddInputDeviceDialog(
                kind: $proposedKind,
                physicalDeviceID: $proposedPhysicalDeviceID,
                nameLabel: $proposedNameLabel,
                numberedName: proposedNumberedName,
                cameras: cameras,
                audioDevices: audioDevices,
                submit: addDevice,
                cancel: { isShowingAddDialog = false }
            )
        }
    }

    @ViewBuilder
    private func inputDeviceRow(_ device: WorkspaceInputDeviceRecord) -> some View {
        let muted = isMuted(device)
        let row = WorkspaceResourceSidebarRow(
            name: device.name,
            systemImage: inputDeviceSystemImage(device, isMuted: muted),
            isDimmed: muted,
            isStrikethrough: muted,
            isSelectionEnabled: isInputDeviceEditable,
            select: { selectedSidebarItem = .inputDevice(device.name) },
            leadingAction: WorkspaceSidebarPane.showsMuteControl(for: device.kind)
                ? { setMuted(!muted, device: device) }
                : nil,
            leadingActionLabel: muted ? "Unmute Input Device" : "Mute Input Device",
            leadingActionIdentifier: "workspaceInputDeviceMuteButton-\(device.name)",
            leadingActionHelp: muted ? "Unmute \(device.name)" : "Mute \(device.name)"
        )
        if isInputDeviceEditable {
            row
                .tag(WorkspaceSidebarItem.inputDevice(device.name))
                .onDrag { draggedName = device.name; return NSItemProvider(object: device.name as NSString) }
                .onDrop(of: [UTType.text], delegate: InputDeviceDropDelegate(
                    destinationName: device.name, inputDevices: $inputDevices,
                    draggedName: $draggedName, isEnabled: true
                ))
        } else {
            row
        }
    }

    private func beginAddingDevice() {
        guard isInputDeviceEditable else { return }
        addDialogWindowState = windowState
        proposedKind = .video
        proposedPhysicalDeviceID = cameras.first?.id
        proposedNameLabel = "Video Capture"
        isShowingAddDialog = true
    }

    private var isInputDeviceEditable: Bool {
        windowState.mode == .edit && !windowState.isOperationLocked
    }

    private func addDevice() {
        guard addDialogWindowState == windowState, isInputDeviceEditable else {
            isShowingAddDialog = false
            return
        }
        let label = proposedNameLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        let option = availablePhysicalDevices.first { $0.id == proposedPhysicalDeviceID }
        let name = WorkspaceResourceNameValidator.nextNumberedName(
            label: label, inputDevices: inputDevices, videoComponents: videoComponents,
            visions: visions
        )
        let device = WorkspaceInputDeviceRecord(
            name: name,
            kind: proposedKind,
            physicalDeviceID: option?.id
        )
        inputDevices.append(device); selectedSidebarItem = .inputDevice(device.name)
        isShowingAddDialog = false
    }

    private var availablePhysicalDevices: [InputPhysicalDeviceOption] {
        proposedKind == .audio ? audioDevices : cameras
    }

    private var proposedNumberedName: String {
        WorkspaceResourceNameValidator.nextNumberedName(
            label: proposedNameLabel, inputDevices: inputDevices, videoComponents: videoComponents,
            visions: visions
        )
    }

    private func isMuted(_ device: WorkspaceInputDeviceRecord) -> Bool {
        switch device.kind {
        case .video: preferences.isVideoMuted(inputDeviceName: device.name)
        case .audio: preferences.isAudioMuted(inputDeviceName: device.name)
        case .unspecified: false
        }
    }

    private func setMuted(_ muted: Bool, device: WorkspaceInputDeviceRecord) {
        switch device.kind {
        case .video: preferences.setVideoMuted(muted, inputDeviceName: device.name)
        case .audio: preferences.setAudioMuted(muted, inputDeviceName: device.name)
        case .unspecified: break
        }
    }

    private func inputDeviceSystemImage(
        _ device: WorkspaceInputDeviceRecord,
        isMuted: Bool
    ) -> String {
        switch device.kind {
        case .video: isMuted ? "video.slash.fill" : "video"
        case .audio: isMuted ? "waveform.slash" : "waveform"
        case .unspecified: "questionmark.square.dashed"
        }
    }
}

private struct AddInputDeviceDialog: View {
    @Binding var kind: WorkspaceInputDeviceKind
    @Binding var physicalDeviceID: String?
    @Binding var nameLabel: String
    let numberedName: String
    let cameras: [InputPhysicalDeviceOption]
    let audioDevices: [InputPhysicalDeviceOption]
    let submit: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Input Device").font(.title2).bold()
            Form {
                Picker("Kind", selection: $kind) {
                    Label("Video", systemImage: "video").tag(WorkspaceInputDeviceKind.video)
                    Label("Audio", systemImage: "waveform").tag(WorkspaceInputDeviceKind.audio)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("addInputDeviceKindPicker")

                Picker("Device", selection: $physicalDeviceID) {
                    Text(kind == .audio ? "No audio device" : "No camera").tag(String?.none)
                    ForEach(availableDevices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .accessibilityIdentifier("addInputPhysicalDevicePicker")

                TextField("Name", text: $nameLabel, prompt: Text("Video Capture"))
                    .accessibilityIdentifier("addInputDeviceNameField")
                LabeledContent("Saved Name", value: numberedName)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                Button("Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onChange(of: kind) { _, newKind in
            physicalDeviceID = availableDevices.first?.id
            nameLabel = newKind == .audio ? "Audio Capture" : "Video Capture"
        }
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
              let destination = inputDevices.firstIndex(where: { $0.name == destinationName }) else { return }
        inputDevices.move(fromOffsets: IndexSet(integer: source), toOffset: source < destination ? destination + 1 : destination)
    }
    func performDrop(info _: DropInfo) -> Bool { draggedName = nil; return isEnabled }
    func dropUpdated(info _: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}
