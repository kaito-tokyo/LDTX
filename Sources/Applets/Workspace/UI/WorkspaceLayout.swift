// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

public struct WorkspaceLayout<Sidebar: View, Content: View, Inspector: View>: View {
  @State private var sidebarWidth: CGFloat = 240
  @State private var inspectorWidth: CGFloat = 320
  let stateService: WorkspaceDocument
  let sidebar: Sidebar
  let content: Content
  let inspector: Inspector

  public init(
    stateService: WorkspaceDocument, sidebar: Sidebar, content: Content, inspector: Inspector
  ) {
    self.stateService = stateService
    self.sidebar = sidebar
    self.content = content
    self.inspector = inspector
  }

  public var body: some View {
    GeometryReader { geometry in
      let dividers =
        (stateService.isSidebarVisible ? 1.0 : 0) + (stateService.isInspectorVisible ? 1 : 0)
      let available = max(0, geometry.size.width - 480 - dividers)
      let inspectorWidth =
        stateService.isInspectorVisible
        ? min(
          self.inspectorWidth, max(240, available - (stateService.isSidebarVisible ? 200 : 0)))
        : 0
      let sidebarWidth =
        stateService.isSidebarVisible
        ? min(self.sidebarWidth, max(200, available - inspectorWidth)) : 0
      HStack(spacing: 0) {
        sidebar.workspaceSidePane(
          width: sidebarWidth, expandedWidth: self.sidebarWidth,
          isVisible: stateService.isSidebarVisible, alignment: .leading)
        if stateService.isSidebarVisible {
          WorkspaceDivider("Sidebar width", axis: .horizontal, value: sidebarWidth) {
            self.sidebarWidth = min(max(200, available - inspectorWidth), max(200, $0))
          }
        }
        content.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        if stateService.isInspectorVisible {
          WorkspaceDivider(
            "Inspector width", axis: .horizontal, value: inspectorWidth, direction: -1
          ) {
            self.inspectorWidth = min(480, max(240, available - sidebarWidth), max(240, $0))
          }
        }
        inspector.workspaceSidePane(
          width: inspectorWidth, expandedWidth: self.inspectorWidth,
          isVisible: stateService.isInspectorVisible, alignment: .trailing)
      }
    }
    .frame(minWidth: stateService.minimumWindowWidth, minHeight: 400)
  }
}

extension View {
  fileprivate func workspaceSidePane(
    width: CGFloat, expandedWidth: CGFloat, isVisible: Bool, alignment: Alignment
  ) -> some View {
    frame(width: isVisible ? width : expandedWidth)
      .frame(width: width, alignment: alignment)
      .clipped()
      .opacity(isVisible ? 1 : 0)
      .allowsHitTesting(isVisible)
      .disabled(!isVisible)
      .accessibilityHidden(!isVisible)
  }
}
