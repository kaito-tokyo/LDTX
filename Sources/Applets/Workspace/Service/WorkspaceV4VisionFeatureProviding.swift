// SPDX-FileCopyrightText: 2026 Kaito Udagawa
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore

@MainActor
public protocol WorkspaceV4VisionFeatureProviding: AnyObject {
  func synchronize(
    visions: [Ldtx_Workspace_V4_VisionWrapper], context: WorkspaceV4VisionFeatureContext)
  func stop() async
  func submit(visionInternalID: Int64, context: WorkspaceV4VisionFeatureContext)
}
