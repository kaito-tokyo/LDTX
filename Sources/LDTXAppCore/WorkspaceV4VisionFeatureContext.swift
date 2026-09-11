// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspace

/// Supplies one V4 Vision feature with live V4 Workspace input frames.
@MainActor
public struct WorkspaceV4VisionFeatureContext {
  public var vision: (UInt64) -> Ldtx_Workspace_V4_OcrVision?
  public var frameForVision: (Ldtx_Workspace_V4_OcrVision) throws -> WorkspaceVisionAnalysisFrame
  public var reportFailure: (UInt64, Error) -> Void

  public init(
    vision: @escaping (UInt64) -> Ldtx_Workspace_V4_OcrVision?,
    frameForVision: @escaping (Ldtx_Workspace_V4_OcrVision) throws -> WorkspaceVisionAnalysisFrame,
    reportFailure: @escaping (UInt64, Error) -> Void
  ) {
    self.vision = vision
    self.frameForVision = frameForVision
    self.reportFailure = reportFailure
  }
}
