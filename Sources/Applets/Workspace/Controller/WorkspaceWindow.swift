// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXWorkspaceAppletInterface
import LDTXWorkspaceAppletUI
import SwiftUI

public final class WorkspaceWindow: NSWindow {
  private let uiState: WorkspaceUIState

  init(
    url: URL,
    deviceRegistry: DeviceRegistryService,
    appletData: WorkspaceAppletData,
    dispatcher: any WorkspaceDispatcherProtocol,
    uiState: WorkspaceUIState,
    documentReference: DocumentReference
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
      deviceRegistry: deviceRegistry,
      uiState: uiState,
      appletData: appletData
    )
    .environment(\.workspaceDispatcher, dispatcher)

    let inspectorView = WorkspaceInspectorContainer(
      deviceRegistry: deviceRegistry,
      uiState: uiState,
      appletData: appletData
    )
    .environment(\.workspaceDispatcher, dispatcher)

    let sidebarController = NSHostingController(
      rootView: sidebarView.environment(\.documentReference, documentReference))
    sidebarController.sizingOptions = [.minSize]

    let contentController = NSHostingController(
      rootView: contentView.environment(\.documentReference, documentReference))
    contentController.sizingOptions = [.minSize]

    let inspectorController = NSHostingController(
      rootView: inspectorView.environment(\.documentReference, documentReference))
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
    // Installing the content controller replaces the initial size with its fitting size.
    self.setContentSize(NSSize(width: 1062, height: 700))

    self.center()
  }

  public override func encodeRestorableState(with coder: NSCoder) {
    super.encodeRestorableState(with: coder)
    coder.encode(
      uiState.inspectorSelector?.asRepresentation(),
      forKey: "tokyo.kaito.ldtx.LDTX.WorkspaceAppletController.v1.inspector")
  }

  public override func restoreState(with coder: NSCoder) {
    super.restoreState(with: coder)
    if let representation = coder.decodeObject(
      of: WorkspaceInspectorSelectorRepresentation.self,
      forKey: "tokyo.kaito.ldtx.LDTX.WorkspaceAppletController.v1.inspector")
    {
      uiState.inspectorSelector = representation.selector
    }
  }
}
