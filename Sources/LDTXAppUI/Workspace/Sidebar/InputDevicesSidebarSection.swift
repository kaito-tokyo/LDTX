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
    let automations: [WorkspaceAutomationDefinition]
    let isEditingEnabled: Bool
    @State private var draggedName: String?
    @State private var isShowingAddDialog = false
    @State private var proposedName = ""

    var body: some View {
        Section {
            if inputDevices.isEmpty { Text("No input devices").foregroundStyle(.secondary) }
            ForEach(Array(inputDevices.enumerated()), id: \.element.name) { index, device in
                InputDeviceSidebarRow(
                    device: device,
                    isMuted: preferences.isVideoMuted(inputDeviceName: device.name),
                    isEditingEnabled: isEditingEnabled,
                    nameIsAvailable: { candidate in
                        WorkspaceResourceNameValidator.isAvailable(
                            candidate, inputDevices: inputDevices, visions: visions,
                            automations: automations, excludingResourceID: device.name
                        )
                    },
                    select: { selectedSidebarItem = .inputDevice(device.name) },
                    rename: { inputDevices[index].name = $0 },
                    toggleMute: { preferences.setVideoMuted(!$0, inputDeviceName: device.name) }
                )
                .tag(WorkspaceSidebarItem.inputDevice(device.name))
                .onDrag { draggedName = device.name; return NSItemProvider(object: device.name as NSString) }
                .onDrop(of: [UTType.text], delegate: InputDeviceDropDelegate(
                    destinationName: device.name, inputDevices: $inputDevices,
                    draggedName: $draggedName, isEnabled: isEditingEnabled
                ))
            }
        } header: {
            WorkspaceSidebarSectionHeader(
                title: "Input Devices", accessibilityIdentifier: "addWorkspaceInputDeviceButton",
                isAddEnabled: isEditingEnabled, add: beginAddingDevice
            )
        }
        .sheet(isPresented: $isShowingAddDialog) {
            ItemNameDialog(
                name: $proposedName,
                title: "Add Input Device",
                fieldTitle: "Input Device Name",
                isNameAvailable: nameIsAvailable,
                submit: addDevice(named:),
                cancel: { isShowingAddDialog = false }
            )
        }
    }

    private func beginAddingDevice() {
        let device = WorkspaceInputDeviceDefaults.makeDefaultVideoInputDevice(existingInputDevices: inputDevices)
        proposedName = WorkspaceResourceNameValidator.uniqueName(
            base: device.name, inputDevices: inputDevices, visions: visions, automations: automations
        )
        isShowingAddDialog = true
    }

    private func nameIsAvailable(_ name: String) -> Bool {
        WorkspaceResourceNameValidator.isAvailable(
            name, inputDevices: inputDevices, visions: visions, automations: automations
        )
    }

    private func addDevice(named name: String) {
        guard nameIsAvailable(name) else { return }
        var device = WorkspaceInputDeviceDefaults.makeDefaultVideoInputDevice(existingInputDevices: inputDevices)
        device.name = name
        inputDevices.append(device); selectedSidebarItem = .inputDevice(device.name)
        isShowingAddDialog = false
    }
}

private struct InputDeviceSidebarRow: View {
    let device: WorkspaceInputDeviceRecord
    let isMuted: Bool
    let isEditingEnabled: Bool
    let nameIsAvailable: (String) -> Bool
    let select: () -> Void
    let rename: (String) -> Void
    let toggleMute: (Bool) -> Void
    @State private var renameSession: InlineRenameSession?
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: device.kind == .audio ? "waveform" : "video")
                .foregroundStyle(isMuted ? .secondary : .primary).frame(width: 16)
            if renameSession != nil {
                TextField("Input Device Name", text: draftBinding)
                    .textFieldStyle(.plain).focused($renameFocused).onSubmit(commitRename)
                    .onExitCommand { renameSession = nil }
                    .accessibilityIdentifier("workspaceSidebarInputDeviceNameField")
            } else { Text(device.name).lineLimit(1).foregroundStyle(isMuted ? .secondary : .primary) }
            Spacer(minLength: 8)
            if device.kind.supportsProgramVideoMute {
                SidebarActionButton(
                    systemImage: isMuted ? "speaker.slash.fill" : "speaker.slash",
                    accessibilityLabel: isMuted ? "Unmute Input Device" : "Mute Input Device",
                    accessibilityIdentifier: "workspaceInputDeviceMuteButton-\(device.name)"
                ) { toggleMute(isMuted) }
            }
            SidebarActionButton(
                systemImage: "pencil", accessibilityLabel: "Rename Input Device",
                accessibilityIdentifier: "workspaceInputDeviceRenameButton-\(device.name)"
            ) { beginRename() }.disabled(!isEditingEnabled)
        }.contentShape(Rectangle()).onTapGesture(perform: select)
    }
    private var draftBinding: Binding<String> {
        Binding(get: { renameSession?.draft ?? "" }, set: { renameSession?.draft = $0 })
    }
    private func beginRename() {
        select(); renameSession = InlineRenameSession(originalName: device.name, draft: device.name); renameFocused = true
    }
    private func commitRename() {
        guard let session = renameSession else { return }
        let candidate = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, nameIsAvailable(candidate) else { return }
        rename(candidate); renameSession = nil
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
