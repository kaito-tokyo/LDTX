// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import SwiftUI

struct ProgramDetailPane: View {
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
    @Binding var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?

    var body: some View {
        Form {
            ProgramDefinitionDevelopmentView(
                mainWindowState: $mainWindowState,
                compositeProgramDefinition: $compositeProgramDefinition,
                inputCameraDeviceMappings: $inputCameraDeviceMappings,
                inputAudioDeviceMappings: $inputAudioDeviceMappings,
                cameras: captureDeviceStore.cameras,
                audioDevices: captureDeviceStore.audioDevices,
                programCameraInputSource: programCameraInputSource,
                selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
                savedProgramDefinitions: savedProgramDefinitions,
                reloadSavedProgramDefinitions: reloadSavedProgramDefinitions,
                refreshCameras: refreshCameras,
                saveProgramDefinitionRecord: saveProgramDefinitionRecord,
                saveProgramDefinitionCommand: $saveProgramDefinitionCommand
            )
        }
        .formStyle(.grouped)
    }
}
