// SPDX-FileCopyrightText: 2026 Kaito Udagawa
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspace

@MainActor
public protocol WorkspaceV4VisionFeatureProviding: AnyObject {
  func synchronize(
    visions: [Ldtx_Workspace_V4_VisionWrapper], context: WorkspaceV4VisionFeatureContext)
  func stop()
  func submit(visionInternalID: UInt64, context: WorkspaceV4VisionFeatureContext)
}
