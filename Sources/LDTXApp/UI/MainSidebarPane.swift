// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace
import SwiftUI

struct MainSidebarPane: View {
    @Binding var mainWindowState: MainWindowState
    @Binding var workspaceInputDevices: [WorkspaceInputDeviceRecord]

    var body: some View {
        VStack(spacing: 0) {
            List(selection: sidebarSelection) {
                Section {
                    Label("Edit Current Program", systemImage: "pencil")
                        .tag(MainSidebarSelection.program)
                        .accessibilityIdentifier("editCurrentProgramSidebarItem")
                }

                Section {
                    if workspaceInputDevices.isEmpty {
                        Text("No input devices")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(workspaceInputDevices) { inputDevice in
                            InputDeviceSidebarRow(inputDevice: inputDevice)
                                .tag(MainSidebarSelection.inputDevice(inputDevice.id))
                        }
                    }
                } header: {
                    HStack {
                        Text("Input Devices")
                        Spacer()
                        addInputDeviceMenu
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("Workspace")
    }

    private var addInputDeviceMenu: some View {
        Menu {
            Button {
                addWorkspaceInputDevice(kind: .video)
            } label: {
                Label("Camera", systemImage: "video")
            }
            .accessibilityIdentifier("addWorkspaceVideoInputDeviceMenuItem")

            Button {
                addWorkspaceInputDevice(kind: .audio)
            } label: {
                Label("Audio", systemImage: "waveform")
            }
            .accessibilityIdentifier("addWorkspaceAudioInputDeviceMenuItem")
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .help("Add Input Device")
        .accessibilityLabel("Add Input Device")
        .accessibilityIdentifier("addWorkspaceInputDeviceMenu")
    }

    private var sidebarSelection: Binding<MainSidebarSelection?> {
        Binding(
            get: {
                switch mainWindowState.selectedSidebarItem {
                case .program:
                    return .program
                case .inputDevice:
                    guard let selectedID = mainWindowState.selectedWorkspaceInputDeviceID else {
                        return .program
                    }
                    return .inputDevice(selectedID)
                }
            },
            set: { selection in
                switch selection {
                case .none:
                    mainWindowState.selectedSidebarItem = .program
                    mainWindowState.selectedWorkspaceInputDeviceID = nil
                case .some(.program):
                    mainWindowState.selectedSidebarItem = .program
                    mainWindowState.selectedWorkspaceInputDeviceID = nil
                case let .some(.inputDevice(id)):
                    mainWindowState.selectedSidebarItem = .inputDevice
                    mainWindowState.selectedWorkspaceInputDeviceID = id
                }
            }
        )
    }

    private func addWorkspaceInputDevice(kind: WorkspaceInputDeviceKind) {
        let inputDevice = WorkspaceInputDeviceRecord(
            name: nextWorkspaceInputDeviceName(kind: kind),
            kind: kind
        )
        workspaceInputDevices.append(inputDevice)
        mainWindowState.selectedSidebarItem = .inputDevice
        mainWindowState.selectedWorkspaceInputDeviceID = inputDevice.id
    }

    private func nextWorkspaceInputDeviceName(kind: WorkspaceInputDeviceKind) -> String {
        let prefix = switch kind {
        case .video:
            "Camera"
        case .audio:
            "Audio"
        case .unspecified:
            "Input"
        }
        let existingNames = Set(
            workspaceInputDevices
                .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        var index = 1
        while existingNames.contains("\(prefix) \(index)") {
            index += 1
        }
        return "\(prefix) \(index)"
    }

}

private struct InputDeviceSidebarRow: View {
    var inputDevice: WorkspaceInputDeviceRecord

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .frame(width: 18, alignment: .center)
            Text(inputDevice.name)
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

private enum MainSidebarSelection: Hashable {
    case program
    case inputDevice(String)
}
