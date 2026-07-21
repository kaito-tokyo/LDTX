// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import SwiftUI

struct WorkspaceContentPane: View {
    @State private var presentedCaptureFrameFeedback: OutputFrameCaptureFeedback?
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
    var programActions: ProgramPreviewActions? = nil
    var captureFrameFeedback: Binding<OutputFrameCaptureFeedback?> = .constant(nil)

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
            updateProgramAudioGains: updateProgramAudioGains,
            programActions: programActions
        )
        .overlay(alignment: .top) {
            if let feedback = presentedCaptureFrameFeedback {
                captureToast(feedback)
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .task(id: captureFrameFeedback.wrappedValue?.id) {
            var removalTransaction = Transaction()
            removalTransaction.disablesAnimations = true
            withTransaction(removalTransaction) {
                presentedCaptureFrameFeedback = nil
            }

            guard let feedback = captureFrameFeedback.wrappedValue else { return }
            await Task.yield()
            guard !Task.isCancelled, captureFrameFeedback.wrappedValue?.id == feedback.id else {
                return
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                presentedCaptureFrameFeedback = feedback
            }

            try? await Task.sleep(for: .seconds(feedback.isError ? 5 : 3))
            guard !Task.isCancelled, captureFrameFeedback.wrappedValue?.id == feedback.id else {
                return
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                presentedCaptureFrameFeedback = nil
            }
            captureFrameFeedback.wrappedValue = nil
        }
    }

    private func captureToast(_ feedback: OutputFrameCaptureFeedback) -> some View {
        HStack(spacing: 10) {
            Image(systemName: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(feedback.isError ? .red : .green)
            Text(feedback.message)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("captureFramesToast")
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
