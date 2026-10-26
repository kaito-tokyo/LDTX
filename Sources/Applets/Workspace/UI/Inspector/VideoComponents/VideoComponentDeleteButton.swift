// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import LDTXWorkspaceAppletModel
import SwiftUI

struct VideoComponentDeleteButton: View {
  @Environment(\.undoManager) private var undoManager
  let stateService: WorkspaceDocument
  let componentID: Int64

  var body: some View {
    Section {
      HStack {
        Spacer()
        Button("Delete", role: .destructive) {
          VideoComponentDeletion.delete(componentID, from: stateService, undoManager: undoManager)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
        .accessibilityIdentifier("deleteVideoComponent")
      }
      if VideoComponentDeletion.hasVisionInputReference(componentID, in: stateService) {
        Text("Change the input of Visions using this component before deleting it.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .disabled(
      stateService.isOutputActive || stateService.isClosed
        || VideoComponentDeletion.hasVisionInputReference(componentID, in: stateService)
        || !stateService.workspaceDefinition.videoComponents.contains {
          $0.internalID == componentID
        })
  }
}

@MainActor
enum VideoComponentDeletion {
  static func hasVisionInputReference(_ componentID: Int64, in stateService: WorkspaceDocument)
    -> Bool
  {
    stateService.workspaceDefinition.visions.contains { wrapper in
      switch wrapper.vision {
      case .ocrVision(let vision):
        (vision.videoComponentInternalID != nil) && vision.videoComponentInternalID == componentID
      case .ldtxSceneDetectorVision(let vision):
        (vision.videoComponentInternalID != nil) && vision.videoComponentInternalID == componentID
      case nil: false
      }
    }
  }

  static func delete(
    _ componentID: Int64, from stateService: WorkspaceDocument, undoManager: UndoManager? = nil
  ) {
    guard !stateService.isOutputActive, !stateService.isClosed,
      !hasVisionInputReference(componentID, in: stateService),
      stateService.workspaceDefinition.videoComponents.contains(where: {
        $0.internalID == componentID
      })
    else { return }

    var definition = stateService.workspaceDefinition
    var preferences = stateService.workspacePreferences
    definition.videoComponents.removeAll { $0.internalID == componentID }
    if definition.canvasConfiguration?.ptsMasterVfxSourceInternalID == componentID {
      definition.canvasConfiguration?.ptsMasterVfxSourceInternalID = nil
    }
    func removingReferences(_ program: Ldtx_Workspace_V4_ProgramPreferences)
      -> Ldtx_Workspace_V4_ProgramPreferences
    {
      var program = program
      program.videoLayerInternalIds.removeAll { $0 == componentID }
      program.videoLayerTransforms.removeValue(forKey: componentID)
      program.videoLayerHidden.removeValue(forKey: componentID)
      return program
    }
    preferences.landscapeProgramPreferences = preferences.landscapeProgramPreferences.mapValues(
      removingReferences)
    preferences.portraitProgramPreferences = preferences.portraitProgramPreferences.mapValues(
      removingReferences)

    // Both sections are one synchronous document edit and one Undo action.
    // Retain app-local device assignments so Undo can restore the source with its device.
    stateService.editWorkspace(undoManager: undoManager) { workspace in
      workspace.definition = definition
      workspace.preferences = preferences
    }
    if stateService.inspectorSelector?.internalID == componentID {
      stateService.inspectorSelector = nil
    }
  }
}
