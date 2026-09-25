// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Observation

@MainActor
@Observable
final class WorkspaceUIStore {
  var selectedItem: WorkspaceSidebarItem? = .preview
}
