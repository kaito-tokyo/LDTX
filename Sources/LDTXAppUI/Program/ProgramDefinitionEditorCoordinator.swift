// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI

struct ProgramDefinitionEditorCoordinator: View {
  @Binding var selectedProgramDefinitionName: String?
  @Binding var compositeProgramDefinition: CompositeProgramDefinition
  @Binding var portraitCompositeProgramDefinition: CompositeProgramDefinition
  @Binding var workspaceInputDevices: [WorkspaceInputDeviceRecord]
  var workspaceVideoComponents: [WorkspaceVideoComponentRecord]
  @Binding var programPreferences: ProgramPreferences
  @Binding var portraitProgramPreferences: ProgramPreferences
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
      .onChange(of: portraitCompositeProgramDefinition) { _, _ in
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
    let landscape = ProgramCanvasDefinition(
      canvasWidth: 1_920,
      canvasHeight: 1_080,
      frameRateNumerator: 60,
      frameRateDenominator: 1,
      composite: outputCanvas.applying(to: compositeProgramDefinition)
    )
    let portrait = ProgramCanvasDefinition(
      canvasWidth: 1_080,
      canvasHeight: 1_920,
      frameRateNumerator: 60,
      frameRateDenominator: 1,
      composite: portraitCompositeProgramDefinition
    )
    return SavedProgramDefinitionRecord(
      name: selectedProgramDefinitionRecord?.name ?? selectedProgramDefinitionName ?? "New Program",
      landscape: landscape,
      portrait: portrait,
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
    portraitCompositeProgramDefinition = WorkspaceVideoComponentResolver.applying(
      workspaceVideoComponents,
      layers: portraitProgramPreferences.videoLayers(forProgramNamed: record.name),
      to: record.portrait.composite
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
