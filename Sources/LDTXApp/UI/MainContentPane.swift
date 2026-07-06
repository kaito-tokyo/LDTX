// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import SwiftUI

struct MainContentPane: View {
    @Binding var mainWindowState: MainWindowState
    var programCameraInputSource: ProgramCameraInputSource
    var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
    var compositeProgramDefinition: CompositeProgramDefinition
    @Binding var programArguments: ProgramArguments
    var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    var inputCameraDeviceMappings: [String: String]
    var audioPeakMeter: ProgramAudioPeakMeter
    var updateProgramAudioGains: (ProgramArguments) -> Void

    var body: some View {
        ProgramContentPane(
            mainWindowState: $mainWindowState,
            programCameraInputSource: programCameraInputSource,
            selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
            compositeProgramDefinition: compositeProgramDefinition,
            programArguments: $programArguments,
            workspaceInputDevices: workspaceInputDevices,
            inputCameraDeviceMappings: inputCameraDeviceMappings,
            audioPeakMeter: audioPeakMeter,
            updateProgramAudioGains: updateProgramAudioGains
        )
    }
}
