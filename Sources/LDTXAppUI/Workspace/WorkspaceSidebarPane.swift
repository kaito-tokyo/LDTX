// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace
import SwiftUI

public struct WorkspaceSidebarPane: View {
    @Binding private var selectedSidebarItem: WorkspaceSidebarItem
    @Binding private var workspaceInputDevices: [WorkspaceInputDeviceRecord]

    public init(
        selectedSidebarItem: Binding<WorkspaceSidebarItem>,
        workspaceInputDevices: Binding<[WorkspaceInputDeviceRecord]>
    ) {
        _selectedSidebarItem = selectedSidebarItem
        _workspaceInputDevices = workspaceInputDevices
    }

    public var body: some View {
        List(selection: selectedListItem) {
            Label("Edit Current Program", systemImage: "pencil")
                .lineLimit(1)
                .tag(WorkspaceSidebarItem.program)
                .accessibilityIdentifier("editCurrentProgramSidebarItem")

            Section {
                if workspaceInputDevices.isEmpty {
                    Text("No input devices")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(workspaceInputDevices) { inputDevice in
                        Label(inputDevice.name, systemImage: inputDevice.iconName)
                            .lineLimit(1)
                            .tag(WorkspaceSidebarItem.inputDevice(inputDevice.id))
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
            get: { selectedSidebarItem },
            set: { newValue in
                if let newValue {
                    selectedSidebarItem = newValue
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
        selectedSidebarItem: .program
    )
}

private struct WorkspaceSidebarPanePreviewHost: View {
    @State private var selectedSidebarItem: WorkspaceSidebarItem
    @State private var workspaceInputDevices: [WorkspaceInputDeviceRecord]

    init(
        workspaceInputDevices: [WorkspaceInputDeviceRecord],
        selectedSidebarItem: WorkspaceSidebarItem
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
