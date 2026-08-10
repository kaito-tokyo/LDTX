// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftUI

struct ProgramDetailPane: View {
  @Binding var selectedProgramDefinitionName: String?
  @Binding var compositeProgramDefinition: CompositeProgramDefinition
  var outputCanvas: OutputCanvasModel
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
        selectedProgramDefinitionName: $selectedProgramDefinitionName,
        compositeProgramDefinition: $compositeProgramDefinition,
        outputCanvas: outputCanvas,
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

#if DEBUG
  #Preview("Program Detail") {
    ProgramDetailPanePreviewHost()
      .frame(width: 560, height: 760)
  }

  private struct ProgramDetailPanePreviewHost: View {
    @State private var selectedProgramDefinitionName =
      LDTXAppUIPreviewFixtures.selectedProgramDefinitionName
    @State private var compositeProgramDefinition = LDTXAppUIPreviewFixtures
      .compositeProgramDefinition
    @State private var outputCanvas = LDTXAppUIPreviewFixtures.makeOutputCanvasModel()
    @State private var workspaceInputDevices = LDTXAppUIPreviewFixtures.workspaceInputDevices
    @State private var saveProgramDefinitionCommand: ProgramDefinitionSaveCommand?

    var body: some View {
      ProgramDetailPane(
        selectedProgramDefinitionName: $selectedProgramDefinitionName,
        compositeProgramDefinition: $compositeProgramDefinition,
        outputCanvas: outputCanvas,
        workspaceInputDevices: $workspaceInputDevices,
        selectedProgramDefinitionRecord: LDTXAppUIPreviewFixtures.selectedProgramDefinitionRecord,
        reloadSavedProgramDefinitions: {},
        refreshCameras: {},
        saveProgramDefinitionRecord: { _ in true },
        programDefinitionDirtyChanged: { _ in },
        saveProgramDefinitionCommand: $saveProgramDefinitionCommand
      )
    }
  }
#endif
