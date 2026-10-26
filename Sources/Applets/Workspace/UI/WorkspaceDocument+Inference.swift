// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs

extension WorkspaceDocument {
  public func inferenceRequest(
    document: (any WorkspaceDocumentContext)?, workspace: WorkspaceV4Bundle?
  ) -> (vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision, url: URL)? {
    guard inspectorSelector?.kind == .ldtxSceneDetectorVision,
      let workspace,
      document?.fileURL != nil,
      let id = inspectorSelector?.internalID,
      let vision = workspace.definition.visions.compactMap({
        wrapper -> Ldtx_Workspace_V4_LdtxSceneDetectorVision? in
        if case .ldtxSceneDetectorVision(let vision)? = wrapper.vision,
          vision.internalID == id
        {
          return vision
        }
        return nil
      }).first,
      let modelID = vision.modelInternalID, modelID > 0,
      workspaceDefinition.visions.contains(where: {
        $0.vision == .ldtxSceneDetectorVision(vision)
      }),
      workspace.definition.videoComponents.contains(where: {
        $0.internalID == vision.videoComponentInternalID && $0.canBeVisionInput
          && $0.renderingSize != nil
      })
    else { return nil }
    guard let url = workspace.visionModels[modelID] else { return nil }
    return (vision, url)
  }

}
