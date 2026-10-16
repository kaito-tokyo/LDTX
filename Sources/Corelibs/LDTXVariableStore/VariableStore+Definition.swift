// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos

extension VariableStore {
  /// Projects a persisted Definition into a fresh, fixed variable inventory.
  public init(definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4) {
    var keys: Set<VariableKey> = []
    for wrapper in definition.visions {
      switch wrapper.vision {
      case .ocrVision(let vision):
        keys.insert(VariableKey(visionID: vision.internalID, item: .text))
      case .ldtxSceneDetectorVision(let vision):
        keys.insert(VariableKey(visionID: vision.internalID, item: .label))
        keys.insert(VariableKey(visionID: vision.internalID, item: .confidence))
      case nil: break
      }
    }
    self.init(keys: keys)
  }
}
