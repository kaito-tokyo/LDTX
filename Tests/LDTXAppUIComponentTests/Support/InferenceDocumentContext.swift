// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
import LDTXWorkspaceAppletUI
import Observation

@MainActor @Observable
final class InferenceDocumentContext: WorkspaceDocumentContext {
  let fileURL: URL? = URL(fileURLWithPath: "/tmp/InferenceFixture.ldtxworkspace")
  var runtimeWorkspace: WorkspaceV4Bundle?

  func adopt(_ store: WorkspaceDocument) {
    var definition = store.workspaceDefinition
    for index in definition.visions.indices {
      definition.visions[index].ldtxSceneDetectorVision.modelInternalID = 5
    }
    store.editWorkspace(undoManager: nil) { workspace in
      workspace.definition = definition
    }
    store.editWorkspace(undoManager: nil) { workspace in
      workspace.visionModels[5] = fileURL!.appendingPathComponent("VisionModels/5/model.mlmodel")
    }
    runtimeWorkspace = WorkspaceV4Bundle(
      definition: definition, preferences: store.workspacePreferences,
      visionModels: store.visionModels)
  }
}
