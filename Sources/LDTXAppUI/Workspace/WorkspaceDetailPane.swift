// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
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
    @Binding var selectedSidebarItem: WorkspaceSidebarItem
    @Binding var selectedProgramDefinitionName: String?
    @Binding var compositeProgramDefinition: CompositeProgramDefinition
    var outputCanvas: OutputCanvasModel
    @Binding var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    var cameras: [InputPhysicalDeviceOption]
    var audioDevices: [InputPhysicalDeviceOption]
    var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
    var reloadSavedProgramDefinitions: () -> Void
    var refreshCameras: () -> Void
    var deleteWorkspaceInputDevice: (String) -> Void
    var saveProgramDefinitionRecord: (SavedProgramDefinitionRecord) -> Bool
    var programDefinitionDirtyChanged: (Bool) -> Void
    @Binding var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?

    var body: some View {
        if selectedInputDeviceExists {
            InputDeviceDetailPane(
                inputDevices: $workspaceInputDevices,
                selectedInputDeviceID: selectedInputDeviceID,
                cameras: cameras,
                audioDevices: audioDevices,
                deleteInputDevice: deleteWorkspaceInputDevice
            )
        } else {
            ProgramDetailPane(
                selectedProgramDefinitionName: $selectedProgramDefinitionName,
                compositeProgramDefinition: $compositeProgramDefinition,
                outputCanvas: outputCanvas,
                workspaceInputDevices: $workspaceInputDevices,
                selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
                reloadSavedProgramDefinitions: reloadSavedProgramDefinitions,
                refreshCameras: refreshCameras,
                saveProgramDefinitionRecord: saveProgramDefinitionRecord,
                programDefinitionDirtyChanged: programDefinitionDirtyChanged,
                saveProgramDefinitionCommand: $saveProgramDefinitionCommand
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
                if case let .inputDevice(id) = selectedSidebarItem {
                    return id
                }
                return nil
            },
            set: { newValue in
                guard let newValue,
                      workspaceInputDevices.contains(where: { $0.id == newValue }) else {
                    selectedSidebarItem = .program
                    return
                }
                selectedSidebarItem = .inputDevice(newValue)
            }
        )
    }
}

#if DEBUG
#Preview("Workspace Detail Program") {
    WorkspaceDetailPaneProgramPreviewHost()
        .frame(width: 560, height: 760)
}

#Preview("Workspace Detail Input Device") {
    WorkspaceDetailPaneInputPreviewHost()
        .frame(width: 560, height: 520)
}

private struct WorkspaceDetailPaneProgramPreviewHost: View {
    @State private var selectedSidebarItem = LDTXAppUIPreviewFixtures.selectedSidebarItem
    @State private var selectedProgramDefinitionName =
        LDTXAppUIPreviewFixtures.selectedProgramDefinitionName
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures.compositeProgramDefinition
    @State private var outputCanvas = LDTXAppUIPreviewFixtures.makeOutputCanvasModel()
    @State private var workspaceInputDevices = LDTXAppUIPreviewFixtures.workspaceInputDevices
    @State private var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?

    var body: some View {
        WorkspaceDetailPane(
            selectedSidebarItem: $selectedSidebarItem,
            selectedProgramDefinitionName: $selectedProgramDefinitionName,
            compositeProgramDefinition: $compositeProgramDefinition,
            outputCanvas: outputCanvas,
            workspaceInputDevices: $workspaceInputDevices,
            cameras: LDTXAppUIPreviewFixtures.cameras,
            audioDevices: LDTXAppUIPreviewFixtures.audioDevices,
            selectedProgramDefinitionRecord: LDTXAppUIPreviewFixtures.selectedProgramDefinitionRecord,
            reloadSavedProgramDefinitions: {},
            refreshCameras: {},
            deleteWorkspaceInputDevice: { _ in },
            saveProgramDefinitionRecord: { _ in true },
            programDefinitionDirtyChanged: { _ in },
            saveProgramDefinitionCommand: $saveProgramDefinitionCommand
        )
    }
}

private struct WorkspaceDetailPaneInputPreviewHost: View {
    @State private var selectedSidebarItem = WorkspaceSidebarItem.inputDevice("workspace-video-1")
    @State private var selectedProgramDefinitionName: String? = "Demo Program"
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures.compositeProgramDefinition
    @State private var outputCanvas = LDTXAppUIPreviewFixtures.makeOutputCanvasModel()
    @State private var workspaceInputDevices = LDTXAppUIPreviewFixtures.workspaceInputDevices
    @State private var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?

    var body: some View {
        WorkspaceDetailPane(
            selectedSidebarItem: $selectedSidebarItem,
            selectedProgramDefinitionName: $selectedProgramDefinitionName,
            compositeProgramDefinition: $compositeProgramDefinition,
            outputCanvas: outputCanvas,
            workspaceInputDevices: $workspaceInputDevices,
            cameras: LDTXAppUIPreviewFixtures.cameras,
            audioDevices: LDTXAppUIPreviewFixtures.audioDevices,
            selectedProgramDefinitionRecord: LDTXAppUIPreviewFixtures.selectedProgramDefinitionRecord,
            reloadSavedProgramDefinitions: {},
            refreshCameras: {},
            deleteWorkspaceInputDevice: { _ in },
            saveProgramDefinitionRecord: { _ in true },
            programDefinitionDirtyChanged: { _ in },
            saveProgramDefinitionCommand: $saveProgramDefinitionCommand
        )
    }
}
#endif
