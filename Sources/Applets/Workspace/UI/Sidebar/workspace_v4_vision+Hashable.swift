// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface

extension Ldtx_Workspace_V4_VisionWrapper: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
