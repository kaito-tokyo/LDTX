// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace
import SwiftUI

public struct MainSidebarPane: View {
    @Binding private var selectedSidebarItem: MainSidebarItem
    @Binding private var workspaceInputDevices: [WorkspaceInputDeviceRecord]

    public init(
        selectedSidebarItem: Binding<MainSidebarItem>,
        workspaceInputDevices: Binding<[WorkspaceInputDeviceRecord]>
    ) {
        _selectedSidebarItem = selectedSidebarItem
        _workspaceInputDevices = workspaceInputDevices
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SidebarSelectableRow(
                    title: "Edit Current Program",
                    systemImage: "pencil",
                    isSelected: selectedSidebarItem == .program
                ) {
                    selectedSidebarItem = .program
                }
                .accessibilityIdentifier("editCurrentProgramSidebarItem")

                inputDevicesHeader
                    .padding(.top, 8)

                if workspaceInputDevices.isEmpty {
                    Text("No input devices")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 22)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(workspaceInputDevices) { inputDevice in
                        Button {
                            selectedSidebarItem = .inputDevice(inputDevice.id)
                        } label: {
                            InputDeviceSidebarRow(
                                inputDevice: inputDevice,
                                isSelected: selectedSidebarItem == .inputDevice(inputDevice.id)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .navigationTitle("Workspace")
    }

    private var inputDevicesHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .center)
                .accessibilityHidden(true)

            Text("Input Devices")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            addInputDeviceButton
        }
        .padding(.vertical, 1)
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

private struct SidebarSelectableRow: View {
    var title: String
    var systemImage: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18, alignment: .center)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .font(.system(size: 13))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

private struct InputDeviceSidebarRow: View {
    var inputDevice: WorkspaceInputDeviceRecord
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .frame(width: 18, alignment: .center)
            Text(inputDevice.name)
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .font(.system(size: 13))
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        }
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch inputDevice.kind {
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
    MainSidebarPanePreviewHost(
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
    MainSidebarPanePreviewHost(
        workspaceInputDevices: [],
        selectedSidebarItem: .program
    )
}

private struct MainSidebarPanePreviewHost: View {
    @State private var selectedSidebarItem: MainSidebarItem
    @State private var workspaceInputDevices: [WorkspaceInputDeviceRecord]

    init(
        workspaceInputDevices: [WorkspaceInputDeviceRecord],
        selectedSidebarItem: MainSidebarItem
    ) {
        _selectedSidebarItem = State(initialValue: selectedSidebarItem)
        _workspaceInputDevices = State(initialValue: workspaceInputDevices)
    }

    var body: some View {
        MainSidebarPane(
            selectedSidebarItem: $selectedSidebarItem,
            workspaceInputDevices: $workspaceInputDevices
        )
        .frame(width: 220, height: 420)
    }
}
#endif
