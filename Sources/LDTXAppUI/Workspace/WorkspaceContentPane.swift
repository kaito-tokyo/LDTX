// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import SwiftUI

struct WorkspaceContentPane: View {
    @Binding var selectedSidebarItem: WorkspaceSidebarItem?
    var selectedProgramDefinitionName: String?
    @Binding var compositeProgramDefinition: CompositeProgramDefinition
    var outputCanvas: OutputCanvasModel
    var outputDestination: OutputDestinationModel
    var workspaceCaptureSessionCoordinator: WorkspaceCaptureSessionCoordinator
    var activeProgramRuntime: ActiveProgramRuntime
    var activeProgramSnapshot: ProgramPreviewSnapshot
    var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
    @Binding var programPreferences: ProgramPreferences
    var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    var workspaceAudioChannels: [ProgramAudioChannel]
    var inputCameraDeviceMappings: [String: String]
    var audioPeakMeter: ProgramAudioPeakMeter
    var inputAudioPassthroughChannelKeys: Binding<Set<String>>
    var updateProgramAudioGains: (ProgramPreferences) -> Void

    var body: some View {
        ProgramContentPane(
            selectedSidebarItem: $selectedSidebarItem,
            selectedProgramDefinitionName: selectedProgramDefinitionName,
            compositeProgramDefinition: $compositeProgramDefinition,
            outputCanvas: outputCanvas,
            outputDestination: outputDestination,
            workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
            activeProgramRuntime: activeProgramRuntime,
            activeProgramSnapshot: activeProgramSnapshot,
            selectedProgramDefinitionRecord: selectedProgramDefinitionRecord,
            programPreferences: $programPreferences,
            workspaceInputDevices: workspaceInputDevices,
            workspaceAudioChannels: workspaceAudioChannels,
            inputCameraDeviceMappings: inputCameraDeviceMappings,
            audioPeakMeter: audioPeakMeter,
            inputAudioPassthroughChannelKeys: inputAudioPassthroughChannelKeys,
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
    @State private var selectedSidebarItem = LDTXAppUIPreviewFixtures.selectedSidebarItem
    @State private var selectedProgramDefinitionName =
        LDTXAppUIPreviewFixtures.selectedProgramDefinitionName
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures.compositeProgramDefinition
    @State private var outputCanvas = LDTXAppUIPreviewFixtures.makeOutputCanvasModel()
    @State private var outputDestination = LDTXAppUIPreviewFixtures.makeOutputDestinationModel()
    @State private var programPreferences = LDTXAppUIPreviewFixtures.programPreferences
    private let workspaceCaptureSessionCoordinator = LDTXAppUIPreviewFixtures.makeWorkspaceCaptureSessionCoordinator()

    private var previewRuntime: ActiveProgramRuntime {
        LDTXAppUIPreviewFixtures.makeActiveProgramRuntime(
            coordinator: workspaceCaptureSessionCoordinator
        )
    }

    private var previewSnapshot: ProgramPreviewSnapshot {
        LDTXAppUIPreviewFixtures.makeActiveProgramSnapshot(
            outputCanvas: outputCanvas,
            compositeProgramDefinition: compositeProgramDefinition,
            workspaceInputDevices: LDTXAppUIPreviewFixtures.workspaceInputDevices,
            workspaceAudioChannels: LDTXAppUIPreviewFixtures.workspaceAudioChannels,
            inputCameraDeviceMappings: LDTXAppUIPreviewFixtures.inputCameraDeviceMappings
        )
    }

    var body: some View {
        WorkspaceContentPane(
            selectedSidebarItem: $selectedSidebarItem,
            selectedProgramDefinitionName: selectedProgramDefinitionName,
            compositeProgramDefinition: $compositeProgramDefinition,
            outputCanvas: outputCanvas,
            outputDestination: outputDestination,
            workspaceCaptureSessionCoordinator: workspaceCaptureSessionCoordinator,
            activeProgramRuntime: previewRuntime,
            activeProgramSnapshot: previewSnapshot,
            selectedProgramDefinitionRecord: LDTXAppUIPreviewFixtures.selectedProgramDefinitionRecord,
            programPreferences: $programPreferences,
            workspaceInputDevices: LDTXAppUIPreviewFixtures.workspaceInputDevices,
            workspaceAudioChannels: LDTXAppUIPreviewFixtures.workspaceAudioChannels,
            inputCameraDeviceMappings: LDTXAppUIPreviewFixtures.inputCameraDeviceMappings,
            audioPeakMeter: LDTXAppUIPreviewFixtures.makeAudioPeakMeter(),
            inputAudioPassthroughChannelKeys: .constant([]),
            updateProgramAudioGains: { programPreferences = $0 }
        )
    }
}
#endif
