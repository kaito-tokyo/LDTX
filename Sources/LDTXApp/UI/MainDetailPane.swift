// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI
import LDTXCapture
import LDTXProgram
import LDTXWorkspace
import SwiftUI

struct ProgramDefinitionSaveCommand {
    var isEnabled: Bool
    var perform: () -> Void
}

struct MainDetailPane: View {
    @Binding var mainWindowState: MainWindowState
    @Binding var compositeProgramDefinition: CompositeProgramDefinition
    @Binding var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    var captureDeviceStore: CaptureDeviceStore
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
                cameras: captureDeviceStore.cameras.map { InputPhysicalDeviceOption(camera: $0) },
                audioDevices: captureDeviceStore.audioDevices.map { InputPhysicalDeviceOption(audioDevice: $0) },
                deleteInputDevice: deleteWorkspaceInputDevice
            )
        } else {
            ProgramDetailPane(
                mainWindowState: $mainWindowState,
                compositeProgramDefinition: $compositeProgramDefinition,
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
                if case let .inputDevice(id) = mainWindowState.selectedSidebarItem {
                    return id
                }
                return nil
            },
            set: { newValue in
                guard let newValue,
                      workspaceInputDevices.contains(where: { $0.id == newValue }) else {
                    mainWindowState.selectedSidebarItem = .program
                    return
                }
                mainWindowState.selectedSidebarItem = .inputDevice(newValue)
            }
        )
    }
}

private extension InputPhysicalDeviceOption {
    init(camera: CameraCaptureSource) {
        self.init(id: camera.id, name: camera.name, isExternal: camera.isExternal)
    }

    init(audioDevice: AudioCaptureSource) {
        self.init(id: audioDevice.id, name: audioDevice.name, isExternal: audioDevice.isExternal)
    }
}
