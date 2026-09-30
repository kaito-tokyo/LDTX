// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXWorkspaceAppletInterface
import LDTXWorkspaceAppletUI
import SwiftUI

public final class WorkspaceWindow: NSWindow {
  private let uiState: WorkspaceUIState

  init(
    url: URL,
    windowRuntime: any WorkspaceWindowRuntimeProtocol,
    appletData: WorkspaceAppletData,
    dispatcher: any WorkspaceDispatcherProtocol,
    uiState: WorkspaceUIState
  ) {
    self.uiState = uiState

    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 1062, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)

    self.representedURL = url
    self.title = url.deletingPathExtension().lastPathComponent
    self.isReleasedWhenClosed = false

    let sidebarView = WorkspaceSidebar(uiState: uiState)
      .environment(\.workspaceDispatcher, dispatcher)

    let contentView = WorkspaceContent(
      windowRuntime: windowRuntime,
      uiState: uiState,
      appletData: appletData
    )
    .environment(\.workspaceDispatcher, dispatcher)

    let inspectorView = WorkspaceInspectorContainer(
      windowRuntime: windowRuntime,
      uiState: uiState,
      appletData: appletData
    )
    .environment(\.workspaceDispatcher, dispatcher)

    let sidebarController = NSHostingController(rootView: sidebarView)
    sidebarController.sizingOptions = [.minSize]

    let contentController = NSHostingController(rootView: contentView)
    contentController.sizingOptions = [.minSize]

    let inspectorController = NSHostingController(rootView: inspectorView)
    inspectorController.sizingOptions = [.minSize]

    let splitViewController = NSSplitViewController()

    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
    sidebarItem.canCollapse = true
    sidebarItem.canCollapseFromWindowResize = false
    sidebarItem.automaticallyAdjustsSafeAreaInsets = false
    splitViewController.addSplitViewItem(sidebarItem)

    let contentItem = NSSplitViewItem(viewController: contentController)
    contentItem.automaticallyAdjustsSafeAreaInsets = false
    splitViewController.addSplitViewItem(contentItem)

    let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorController)
    inspectorItem.canCollapse = true
    inspectorItem.canCollapseFromWindowResize = false
    inspectorItem.automaticallyAdjustsSafeAreaInsets = false
    splitViewController.addSplitViewItem(inspectorItem)

    self.contentViewController = splitViewController

    self.center()
  }

  public override func encodeRestorableState(with coder: NSCoder) {
    super.encodeRestorableState(with: coder)
    WorkspaceRestoration.encodeRestorableState(
      representedURL: representedURL, inspectorSelector: uiState.inspectorSelector, with: coder)
  }
}
