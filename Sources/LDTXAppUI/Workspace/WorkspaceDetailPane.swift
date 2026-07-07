// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import SwiftUI

public struct ProgramDefinitionSaveCommand {
    public var isEnabled: Bool
    public var perform: () -> Void

    public init(isEnabled: Bool, perform: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

struct WorkspaceDetailPane: View {
    @Binding var selectedSidebarItem: WorkspaceSidebarItem?
    @Binding var compositeProgramDefinition: CompositeProgramDefinition
    var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
    @Binding var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    var cameras: [InputPhysicalDeviceOption]
    var audioDevices: [InputPhysicalDeviceOption]
    var refreshCameras: () -> Void
    var deleteWorkspaceInputDevice: (String) -> Void
    var workspaceInputDeviceOptions: [WorkspaceInputDeviceRecord]

    var body: some View {
        if selectedInputDeviceExists {
            InputDeviceDetailPane(
                inputDevices: $workspaceInputDevices,
                selectedInputDeviceID: selectedInputDeviceID,
                workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
                cameras: cameras,
                audioDevices: audioDevices,
                refreshPhysicalDevices: refreshCameras,
                deleteInputDevice: deleteWorkspaceInputDevice
            )
        } else if selectedVideoComponentExists {
            VideoComponentDetailPane(
                compositeProgramDefinition: $compositeProgramDefinition,
                selectedSidebarItem: $selectedSidebarItem,
                workspaceInputDevices: workspaceInputDeviceOptions
            )
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "slider.horizontal.3",
                description: Text("Select an input device in the sidebar or a video component in the content pane.")
            )
        }
    }

    private var selectedInputDeviceExists: Bool {
        guard let selectedID = selectedInputDeviceID.wrappedValue else {
            return false
        }
        return workspaceInputDevices.contains { $0.id == selectedID }
    }

    private var selectedInputDeviceID: Binding<String?> {
        Binding(
            get: {
                if case let .some(.inputDevice(id)) = selectedSidebarItem {
                    return id
                }
                return nil
            },
            set: { newValue in
                guard let newValue,
                      workspaceInputDevices.contains(where: { $0.id == newValue }) else {
                    selectedSidebarItem = nil
                    return
                }
                selectedSidebarItem = .inputDevice(newValue)
            }
        )
    }

    private var selectedVideoComponentExists: Bool {
        guard case let .some(.videoComponent(id)) = selectedSidebarItem else {
            return false
        }
        return compositeProgramDefinition.steps.contains { $0.id == id }
    }
}

#if DEBUG
#Preview("Workspace Detail Empty") {
    WorkspaceDetailPaneEmptyPreviewHost()
        .frame(width: 560, height: 760)
}

#Preview("Workspace Detail Input Device") {
    WorkspaceDetailPaneInputPreviewHost()
        .frame(width: 560, height: 520)
}

private struct WorkspaceDetailPaneEmptyPreviewHost: View {
    @State private var selectedSidebarItem = LDTXAppUIPreviewFixtures.selectedSidebarItem
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures.compositeProgramDefinition
    @State private var workspaceInputDevices = LDTXAppUIPreviewFixtures.workspaceInputDevices

    var body: some View {
        WorkspaceDetailPane(
            selectedSidebarItem: $selectedSidebarItem,
            compositeProgramDefinition: $compositeProgramDefinition,
            workspaceCaptureSessionCoordinator: LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator(),
            workspaceInputDevices: $workspaceInputDevices,
            cameras: LDTXAppUIPreviewFixtures.cameras,
            audioDevices: LDTXAppUIPreviewFixtures.audioDevices,
            refreshCameras: {},
            deleteWorkspaceInputDevice: { _ in },
            workspaceInputDeviceOptions: workspaceInputDevices
        )
    }
}

private struct WorkspaceDetailPaneInputPreviewHost: View {
    @State private var selectedSidebarItem: WorkspaceSidebarItem? = .inputDevice("workspace-video-1")
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures.compositeProgramDefinition
    @State private var workspaceInputDevices = LDTXAppUIPreviewFixtures.workspaceInputDevices

    var body: some View {
        WorkspaceDetailPane(
            selectedSidebarItem: $selectedSidebarItem,
            compositeProgramDefinition: $compositeProgramDefinition,
            workspaceCaptureSessionCoordinator: LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator(),
            workspaceInputDevices: $workspaceInputDevices,
            cameras: LDTXAppUIPreviewFixtures.cameras,
            audioDevices: LDTXAppUIPreviewFixtures.audioDevices,
            refreshCameras: {},
            deleteWorkspaceInputDevice: { _ in },
            workspaceInputDeviceOptions: workspaceInputDevices
        )
    }
}
#endif
