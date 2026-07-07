// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace
import SwiftUI
import UniformTypeIdentifiers

public struct WorkspaceSidebarPane: View {
    @Binding private var selectedSidebarItem: WorkspaceSidebarItem?
    @Binding private var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    @State private var draggedInputDeviceID: String?
    @State private var renamingInputDeviceID: String?
    @FocusState private var focusedRenameInputDeviceID: String?

    public init(
        selectedSidebarItem: Binding<WorkspaceSidebarItem?>,
        workspaceInputDevices: Binding<[WorkspaceInputDeviceRecord]>
    ) {
        _selectedSidebarItem = selectedSidebarItem
        _workspaceInputDevices = workspaceInputDevices
    }

    public var body: some View {
        List(selection: selectedListItem) {
            Section {
                if workspaceInputDevices.isEmpty {
                    Text("No input devices")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(workspaceInputDevices.enumerated()), id: \.element.id) { index, inputDevice in
                        inputDeviceRow(for: index)
                            .tag(WorkspaceSidebarItem.inputDevice(inputDevice.id))
                            .onDrag {
                                let inputDeviceID = inputDevice.id
                                draggedInputDeviceID = inputDeviceID
                                return NSItemProvider(object: inputDeviceID as NSString)
                            } preview: {
                                Color.clear
                                    .frame(width: 1, height: 1)
                            }
                            .onDrop(
                                of: [UTType.text],
                                delegate: WorkspaceInputDeviceDropDelegate(
                                    destinationInputDeviceID: inputDevice.id,
                                    workspaceInputDevices: $workspaceInputDevices,
                                    draggedInputDeviceID: $draggedInputDeviceID
                                )
                            )
                    }
                }
            } header: {
                inputDevicesHeader
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Workspace")
    }

    private var selectedListItem: Binding<WorkspaceSidebarItem?> {
        Binding(
            get: {
                guard case .some(.inputDevice(_)) = selectedSidebarItem else {
                    return nil
                }
                return selectedSidebarItem
            },
            set: { newValue in
                selectedSidebarItem = newValue
                if let newValue {
                    if case let .inputDevice(inputDeviceID) = newValue,
                       renamingInputDeviceID != inputDeviceID {
                        finishRenamingInputDevice()
                    }
                } else {
                    finishRenamingInputDevice()
                }
            }
        )
    }

    private var inputDevicesHeader: some View {
        HStack {
            Text("Input Devices")

            Spacer()

            addInputDeviceButton
        }
        .frame(maxWidth: .infinity, minHeight: 24)
    }

    private var addInputDeviceButton: some View {
        SidebarActionButton(
            systemImage: "plus",
            accessibilityLabel: "Add Input Device",
            accessibilityIdentifier: "addWorkspaceInputDeviceButton"
        ) {
            addWorkspaceInputDevice()
        }
    }

    private func addWorkspaceInputDevice() {
        let inputDevice = WorkspaceInputDeviceDefaults.makeDefaultVideoInputDevice(
            existingInputDevices: workspaceInputDevices
        )
        workspaceInputDevices.append(inputDevice)
        selectedSidebarItem = .inputDevice(inputDevice.id)
    }

    @ViewBuilder
    private func inputDeviceRow(for index: Int) -> some View {
        let inputDevice = workspaceInputDevices[index]
        let spotlight = spotlight(for: index)
        let isMuted = inputDevice.isMuted

        HStack(spacing: 8) {
            Image(systemName: inputDevice.iconName)
                .foregroundStyle(isMuted ? .secondary : (spotlight?.accentColor ?? .secondary))
                .frame(width: 16)

            if isEditingName(for: inputDevice.id) {
                TextField("Input Device Name", text: inputDeviceNameBinding(for: index))
                    .textFieldStyle(.plain)
                    .focused($focusedRenameInputDeviceID, equals: inputDevice.id)
                    .onSubmit {
                        finishRenamingInputDevice()
                    }
                    .accessibilityIdentifier("workspaceSidebarInputDeviceNameField")
            } else {
                Text(inputDevice.name)
                    .lineLimit(1)
                    .foregroundStyle(isMuted ? .secondary : .primary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                inputDeviceMuteButton(for: index)
                inputDeviceRenameButton(for: inputDevice.id)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedSidebarItem = .inputDevice(inputDevice.id)
        }
    }

    private func inputDeviceNameBinding(for index: Int) -> Binding<String> {
        Binding(
            get: { workspaceInputDevices[index].name },
            set: { newValue in
                var updated = workspaceInputDevices[index]
                updated.name = newValue
                workspaceInputDevices[index] = updated
            }
        )
    }

    private func isEditingName(for inputDeviceID: String) -> Bool {
        renamingInputDeviceID == inputDeviceID
    }

    private func finishRenamingInputDevice() {
        renamingInputDeviceID = nil
        focusedRenameInputDeviceID = nil
    }

    private func inputDeviceMuteButton(for index: Int) -> some View {
        let inputDevice = workspaceInputDevices[index]
        let isMuted = inputDevice.isMuted
        return SidebarActionButton(
            systemImage: isMuted ? "speaker.slash.fill" : "speaker.slash",
            accessibilityLabel: isMuted ? "Unmute Input Device" : "Mute Input Device",
            accessibilityIdentifier: "workspaceInputDeviceMuteButton-\(inputDevice.id)"
        ) {
            var updated = inputDevice
            updated.setMuted(!isMuted)
            workspaceInputDevices[index] = updated
        }
    }

    private func inputDeviceRenameButton(for inputDeviceID: String) -> some View {
        SidebarActionButton(
            systemImage: "pencil",
            accessibilityLabel: "Rename Input Device",
            accessibilityIdentifier: "workspaceInputDeviceRenameButton-\(inputDeviceID)"
        ) {
            selectedSidebarItem = .inputDevice(inputDeviceID)
            renamingInputDeviceID = inputDeviceID
            focusedRenameInputDeviceID = inputDeviceID
        }
    }

    private func spotlight(for index: Int) -> InputDeviceSpotlight? {
        guard workspaceInputDevices.indices.contains(index) else {
            return nil
        }
        let inputDevice = workspaceInputDevices[index]
        switch inputDevice.kind {
        case .video:
            guard workspaceInputDevices.firstIndex(where: { $0.kind == .video }) == index else {
                return nil
            }
            return InputDeviceSpotlight(
                accentColor: .orange
            )
        case .audio:
            guard workspaceInputDevices.firstIndex(where: { $0.kind == .audio }) == index else {
                return nil
            }
            return InputDeviceSpotlight(
                accentColor: .teal
            )
        case .unspecified:
            return nil
        }
    }
}

private struct InputDeviceSpotlight {
    var accentColor: Color
}

private struct WorkspaceInputDeviceDropDelegate: DropDelegate {
    var destinationInputDeviceID: String
    @Binding var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    @Binding var draggedInputDeviceID: String?

    func dropEntered(info _: DropInfo) {
        guard let draggedInputDeviceID,
              draggedInputDeviceID != destinationInputDeviceID,
              let sourceIndex = workspaceInputDevices.firstIndex(where: { $0.id == draggedInputDeviceID }),
              let destinationIndex = workspaceInputDevices.firstIndex(where: { $0.id == destinationInputDeviceID })
        else {
            return
        }

        if workspaceInputDevices[destinationIndex].id != draggedInputDeviceID {
            withAnimation(.snappy(duration: 0.16)) {
                workspaceInputDevices.move(
                    fromOffsets: IndexSet(integer: sourceIndex),
                    toOffset: sourceIndex < destinationIndex ? destinationIndex + 1 : destinationIndex
                )
            }
        }
    }

    func performDrop(info _: DropInfo) -> Bool {
        draggedInputDeviceID = nil
        return true
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {}
}

private struct SidebarActionButton: View {
    var systemImage: String
    var accessibilityLabel: String
    var accessibilityIdentifier: String
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? Color.secondary.opacity(0.12) : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
        .onHover { isHovered = $0 }
    }
}

private extension WorkspaceInputDeviceRecord {
    var iconName: String {
        switch kind {
        case .video:
            "video"
        case .audio:
            "waveform"
        case .unspecified:
            "questionmark.circle"
        }
    }
}

#if DEBUG
#Preview("Main Sidebar") {
    WorkspaceSidebarPanePreviewHost(
        workspaceInputDevices: [
            WorkspaceInputDeviceRecord(
                id: "preview-video-input",
                name: "Input 1",
                kind: .video
            ),
            WorkspaceInputDeviceRecord(
                id: "preview-audio-input",
                name: "Input 2",
                kind: .audio
            )
        ],
        selectedSidebarItem: .inputDevice("preview-video-input")
    )
}

#Preview("Main Sidebar Empty") {
    WorkspaceSidebarPanePreviewHost(
        workspaceInputDevices: [],
        selectedSidebarItem: nil
    )
}

private struct WorkspaceSidebarPanePreviewHost: View {
    @State private var selectedSidebarItem: WorkspaceSidebarItem?
    @State private var workspaceInputDevices: [WorkspaceInputDeviceRecord]

    init(
        workspaceInputDevices: [WorkspaceInputDeviceRecord],
        selectedSidebarItem: WorkspaceSidebarItem?
    ) {
        _selectedSidebarItem = State(initialValue: selectedSidebarItem)
        _workspaceInputDevices = State(initialValue: workspaceInputDevices)
    }

    var body: some View {
        WorkspaceSidebarPane(
            selectedSidebarItem: $selectedSidebarItem,
            workspaceInputDevices: $workspaceInputDevices
        )
        .frame(width: 220, height: 420)
    }
}
#endif
