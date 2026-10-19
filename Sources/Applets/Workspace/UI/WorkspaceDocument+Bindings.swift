// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

extension Bindable where Value == WorkspaceDocument {
  @MainActor
  func ocrVision(internalID: Int64, undoManager: UndoManager? = nil) -> Binding<
    Ldtx_Workspace_V4_OcrVision
  >? {
    let store = wrappedValue
    func currentVision() -> Ldtx_Workspace_V4_OcrVision? {
      store.workspaceDefinition.visions.compactMap { wrapper in
        guard case .ocrVision(let vision) = wrapper.vision,
          vision.internalID == internalID
        else { return nil }
        return vision
      }.first
    }
    guard let initial = currentVision() else { return nil }
    return Binding(
      // A removed item may still be read while SwiftUI tears down its Inspector.
      get: { currentVision() ?? initial },
      set: { updated in
        guard updated.internalID == internalID,
          let index = store.workspaceDefinition.visions.firstIndex(where: {
            guard case .ocrVision(let vision) = $0.vision else { return false }
            return vision.internalID == internalID
          })
        else { return }
        store.editWorkspace(undoManager: undoManager) { workspace in
          workspace.definition.visions[index].vision = .ocrVision(updated)
        }
      })
  }
  @MainActor
  func ldtxSceneDetectorVision(internalID: Int64, undoManager: UndoManager? = nil) -> Binding<
    Ldtx_Workspace_V4_LdtxSceneDetectorVision
  >? {
    let store = wrappedValue
    func currentVision() -> Ldtx_Workspace_V4_LdtxSceneDetectorVision? {
      store.workspaceDefinition.visions.compactMap { wrapper in
        guard case .ldtxSceneDetectorVision(let vision) = wrapper.vision,
          vision.internalID == internalID
        else { return nil }
        return vision
      }.first
    }
    guard let initial = currentVision() else { return nil }
    return Binding(
      // A removed item may still be read while SwiftUI tears down its Inspector.
      get: { currentVision() ?? initial },
      set: { updated in
        guard updated.internalID == internalID,
          let index = store.workspaceDefinition.visions.firstIndex(where: {
            guard case .ldtxSceneDetectorVision(let vision) = $0.vision else {
              return false
            }
            return vision.internalID == internalID
          })
        else { return }
        store.editWorkspace(undoManager: undoManager) { workspace in
          workspace.definition.visions[index].vision = .ldtxSceneDetectorVision(updated)
        }
      })
  }
}
