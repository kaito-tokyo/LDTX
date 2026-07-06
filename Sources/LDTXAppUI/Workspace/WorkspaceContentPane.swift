// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import SwiftUI

struct WorkspaceContentPane: View {
    @Binding var compositeProgramDefinition: CompositeProgramDefinition
    var outputCanvas: OutputCanvasModel
    var outputDestination: OutputDestinationModel
    var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
    var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
    @Binding var programArguments: ProgramArguments
    var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    var inputCameraDeviceMappings: [String: String]
    var audioPeakMeter: ProgramAudioPeakMeter
    var updateProgramAudioGains: (ProgramArguments) -> Void

    var body: some View {
        ProgramContentPane(
            compositeProgramDefinition: $compositeProgramDefinition,
            outputCanvas: outputCanvas,
            outputDestination: outputDestination,
            workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
            selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
            programArguments: $programArguments,
            workspaceInputDevices: workspaceInputDevices,
            inputCameraDeviceMappings: inputCameraDeviceMappings,
            audioPeakMeter: audioPeakMeter,
            updateProgramAudioGains: updateProgramAudioGains
        )
    }
}

#if DEBUG
#Preview("Workspace Content") {
    WorkspaceContentPanePreviewHost()
        .frame(width: 560, height: 620)
}

private struct WorkspaceContentPanePreviewHost: View {
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures.compositeProgramDefinition
    @State private var outputCanvas = LDTXAppUIPreviewFixtures.makeOutputCanvasModel()
    @State private var outputDestination = LDTXAppUIPreviewFixtures.makeOutputDestinationModel()
    @State private var programArguments = LDTXAppUIPreviewFixtures.programArguments

    var body: some View {
        WorkspaceContentPane(
            compositeProgramDefinition: $compositeProgramDefinition,
            outputCanvas: outputCanvas,
            outputDestination: outputDestination,
            workspaceCaptureSessionCoordinator: LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator(),
            selectedProgramDefinitionRecord: LDTXAppUIPreviewFixtures.selectedProgramDefinitionRecord,
            programArguments: $programArguments,
            workspaceInputDevices: LDTXAppUIPreviewFixtures.workspaceInputDevices,
            inputCameraDeviceMappings: LDTXAppUIPreviewFixtures.inputCameraDeviceMappings,
            audioPeakMeter: LDTXAppUIPreviewFixtures.makeAudioPeakMeter(),
            updateProgramAudioGains: { programArguments = $0 }
        )
    }
}
#endif
