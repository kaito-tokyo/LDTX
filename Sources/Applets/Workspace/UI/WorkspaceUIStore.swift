// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import Observation

@MainActor
@Observable
public final class WorkspaceUIStore {
  public var selectedItem: WorkspaceSidebarItem? = .videoLayers
  public init() {}
}
