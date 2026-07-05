// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

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
        switch mainWindowState.selectedSidebarItem {
        case .program:
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
        case .inputDevice:
            InputDeviceDetailPane(
                inputDevices: $workspaceInputDevices,
                selectedInputDeviceID: $mainWindowState.selectedWorkspaceInputDeviceID,
                cameras: captureDeviceStore.cameras,
                audioDevices: captureDeviceStore.audioDevices,
                deleteInputDevice: deleteWorkspaceInputDevice
            )
        }
    }
}
