// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import LDTXWorkspaceAppletModel
import SwiftUI

struct VideoComponentDeleteButton: View {
  let stateService: WorkspaceStateService
  let componentID: Int64

  var body: some View {
    Section {
      HStack {
        Spacer()
        Button("Delete", role: .destructive) {
          VideoComponentDeletion.delete(componentID, from: stateService)
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
  static func hasVisionInputReference(_ componentID: Int64, in stateService: WorkspaceStateService)
    -> Bool
  {
    stateService.workspaceDefinition.visions.contains { wrapper in
      switch wrapper.vision {
      case .ocrVision(let vision):
        vision.hasVideoComponentInternalID && vision.videoComponentInternalID == componentID
      case .ldtxSceneDetectorVision(let vision):
        vision.hasVideoComponentInternalID && vision.videoComponentInternalID == componentID
      case nil: false
      }
    }
  }

  static func delete(_ componentID: Int64, from stateService: WorkspaceStateService) {
    guard !stateService.isOutputActive, !stateService.isClosed,
      !hasVisionInputReference(componentID, in: stateService),
      stateService.workspaceDefinition.videoComponents.contains(where: {
        $0.internalID == componentID
      })
    else { return }

    var definition = stateService.workspaceDefinition
    var preferences = stateService.workspacePreferences
    definition.videoComponents.removeAll { $0.internalID == componentID }
    if definition.canvasConfiguration.hasPtsMasterVfxSourceInternalID,
      definition.canvasConfiguration.ptsMasterVfxSourceInternalID == componentID
    {
      definition.canvasConfiguration.clearPtsMasterVfxSourceInternalID()
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

    // Both content assignments participate in the document connection's Workspace Undo snapshot.
    // Retain app-local device assignments so Undo can restore the source with its device.
    stateService.workspaceDefinition = definition
    stateService.workspacePreferences = preferences
    if stateService.inspectorSelector?.internalID == componentID {
      stateService.inspectorSelector = nil
    }
  }
}
