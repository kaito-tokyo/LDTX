// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import SwiftUI

struct ProgramDefinitionSaveCommand {
    var isEnabled: Bool
    var perform: () -> Void
}

struct MainDetailPane: View {
    @Binding var mainWindowState: MainWindowState
    @Binding var compositeProgramDefinition: CompositeProgramDefinition
    @Binding var inputCameraDeviceMappings: [String: String]
    @Binding var inputAudioDeviceMappings: [String: String]
    var captureDeviceStore: CaptureDeviceStore
    var programCameraInputSource: ProgramCameraInputSource
    var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
    var savedProgramDefinitions: [SavedProgramDefinitionRecord]
    var reloadSavedProgramDefinitions: () -> Void
    var refreshCameras: () -> Void
    var saveProgramDefinitionRecord: (SavedProgramDefinitionRecord) -> Bool
    var programDefinitionDirtyChanged: (Bool) -> Void
    @Binding var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?

    var body: some View {
        ProgramDetailPane(
            mainWindowState: $mainWindowState,
            compositeProgramDefinition: $compositeProgramDefinition,
            inputCameraDeviceMappings: $inputCameraDeviceMappings,
            inputAudioDeviceMappings: $inputAudioDeviceMappings,
            captureDeviceStore: captureDeviceStore,
            programCameraInputSource: programCameraInputSource,
            selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
            savedProgramDefinitions: savedProgramDefinitions,
            reloadSavedProgramDefinitions: reloadSavedProgramDefinitions,
            refreshCameras: refreshCameras,
            saveProgramDefinitionRecord: saveProgramDefinitionRecord,
            programDefinitionDirtyChanged: programDefinitionDirtyChanged,
            saveProgramDefinitionCommand: $saveProgramDefinitionCommand
        )
    }
}
