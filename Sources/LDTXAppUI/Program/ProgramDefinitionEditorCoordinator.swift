// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI

struct ProgramDefinitionEditorCoordinator: View {
    @Binding var selectedProgramDefinitionName: String?
    @Binding var compositeProgramDefinition: CompositeProgramDefinition
    @Binding var workspaceInputDevices: [WorkspaceInputDeviceRecord]
    var workspaceVideoComponents: [WorkspaceVideoComponentRecord]
    @Binding var programPreferences: ProgramPreferences
    var outputCanvas: OutputCanvasModel
    var selectedProgramDefinitionRecord: SavedProgramDefinitionRecord?
    var reloadSavedProgramDefinitions: () -> Void
    var refreshCameras: () -> Void
    var saveProgramDefinitionRecord: (SavedProgramDefinitionRecord) -> Bool
    var programDefinitionDirtyChanged: (Bool) -> Void
    @Binding var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?
    @State private var isProgramDefinitionDirty = false
    @State private var isApplyingSavedProgramDefinition = false

    var body: some View {
        Color.clear
            .onAppear {
                reloadSavedProgramDefinitions()
                if let selectedDefinition = selectedProgramDefinitionRecord {
                    applySavedProgramDefinition(selectedDefinition, isDirty: false)
                }
                refreshCameras()
                publishEditorStateAfterViewUpdate(isDirty: isProgramDefinitionDirty)
            }
            .onChange(of: compositeProgramDefinition) { _, _ in
                markProgramDefinitionDirty()
            }
            .onChange(of: selectedProgramDefinitionName) { _, _ in
                publishEditorStateAfterViewUpdate(isDirty: isProgramDefinitionDirty)
            }
            .onChange(of: selectedProgramDefinitionRecord) { _, record in
                if let record {
                    applySavedProgramDefinition(record, isDirty: false)
                }
                publishEditorStateAfterViewUpdate(isDirty: isProgramDefinitionDirty)
            }
            .onChange(of: isProgramDefinitionDirty) { _, isDirty in
                publishEditorStateAfterViewUpdate(isDirty: isDirty)
            }
            .onDisappear {
                clearEditorStateAfterViewUpdate()
            }
    }

    private func saveProgramDefinition() {
        let record = currentProgramDefinitionRecord

        if saveProgramDefinitionRecord(record) {
            selectedProgramDefinitionName = record.name
            isProgramDefinitionDirty = false
            programDefinitionDirtyChanged(false)
            refreshSaveProgramDefinitionCommand()
        }
    }

    private func markProgramDefinitionDirty() {
        if !isApplyingSavedProgramDefinition {
            isProgramDefinitionDirty = true
        }
    }

    private var canSaveProgramDefinition: Bool {
        isProgramDefinitionDirty && selectedProgramDefinitionName != nil
    }

    private func refreshSaveProgramDefinitionCommand() {
        saveProgramDefinitionCommand = ProgramDefinitionSaveCommand(
            isEnabled: canSaveProgramDefinition,
            perform: {
                saveProgramDefinition()
            }
        )
    }

    private func publishEditorStateAfterViewUpdate(isDirty: Bool) {
        DispatchQueue.main.async {
            programDefinitionDirtyChanged(isDirty)
            refreshSaveProgramDefinitionCommand()
        }
    }

    private func clearEditorStateAfterViewUpdate() {
        DispatchQueue.main.async {
            programDefinitionDirtyChanged(false)
            saveProgramDefinitionCommand = nil
        }
    }

    private var currentProgramDefinitionRecord: SavedProgramDefinitionRecord {
        SavedProgramDefinitionRecord(
            name: selectedProgramDefinitionRecord?.name ?? selectedProgramDefinitionName ?? "New Program",
            canvasWidth: outputCanvas.canvasSize.width,
            canvasHeight: outputCanvas.canvasSize.height,
            frameRateNumerator: max(outputCanvas.programDefinitionFrameRate, 1),
            frameRateDenominator: 1,
            composite: outputCanvas.applying(to: compositeProgramDefinition),
            inputDevices: []
        )
    }

    private func applySavedProgramDefinition(
        _ record: SavedProgramDefinitionRecord,
        isDirty: Bool
    ) {
        isApplyingSavedProgramDefinition = true
        compositeProgramDefinition = WorkspaceVideoComponentResolver.applying(
            workspaceVideoComponents,
            layers: programPreferences.videoLayers(forProgramNamed: record.name),
            to: record.composite
        )
        isProgramDefinitionDirty = isDirty
        programDefinitionDirtyChanged(isDirty)
        DispatchQueue.main.async {
            isApplyingSavedProgramDefinition = false
            isProgramDefinitionDirty = isDirty
            programDefinitionDirtyChanged(isDirty)
        }
    }
}
