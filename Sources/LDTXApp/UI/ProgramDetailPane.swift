// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI

struct ProgramDetailPane: View {
    @Binding var mainWindowState: MainWindowState
    @Binding var compositeProgramDefinition: CompositeProgramDefinition
    @Binding var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
    var reloadSavedProgramDefinitions: () -> Void
    var refreshCameras: () -> Void
    var saveProgramDefinitionRecord: (SavedProgramDefinitionRecord) -> Bool
    var programDefinitionDirtyChanged: (Bool) -> Void
    @Binding var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?

    var body: some View {
        Form {
            ProgramDefinitionDevelopmentView(
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
        .formStyle(.grouped)
    }
}
