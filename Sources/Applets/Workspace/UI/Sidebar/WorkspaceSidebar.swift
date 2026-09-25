// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

public struct WorkspaceSidebar: View {
  let workspaceBundleStore: any WorkspaceBundleStoreProtocol
  @Bindable var workspaceUIStore: WorkspaceUIStore

  public init(
    workspaceBundleStore: any WorkspaceBundleStoreProtocol, workspaceUIStore: WorkspaceUIStore
  ) {
    self.workspaceBundleStore = workspaceBundleStore
    self.workspaceUIStore = workspaceUIStore
  }

  public var body: some View {
    List(selection: $workspaceUIStore.selectedItem) {
      Label("Preview", systemImage: "play.rectangle")
        .tag(WorkspaceSidebarItem.preview)
      Label("Video Layers", systemImage: "square.stack.3d.up")
        .tag(WorkspaceSidebarItem.videoLayers)
      Label("Canvas", systemImage: "rectangle.on.rectangle")
        .tag(WorkspaceSidebarItem.canvas)
    }
    .listStyle(.sidebar)
    .accessibilityIdentifier("workspaceSidebar")
  }
}

#Preview("Workspace Sidebar") {
  WorkspaceSidebar(
    workspaceBundleStore: PreviewWorkspaceBundleStore(),
    workspaceUIStore: WorkspaceUIStore()
  )
  .frame(width: 260, height: 640)
}
