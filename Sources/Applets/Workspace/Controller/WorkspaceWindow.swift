// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXWorkspaceAppletInterface
import LDTXWorkspaceAppletUI
import SwiftUI

public final class WorkspaceWindow: NSWindow, NSToolbarDelegate, NSToolbarItemValidation {
  let contentPane: WorkspaceContent
  private let uiState: WorkspaceUIState
  private let dispatcher: any WorkspaceDispatcherProtocol

  init(
    url: URL,
    deviceRegistry: DeviceRegistryService,
    appletData: WorkspaceAppletData,
    dispatcher: any WorkspaceDispatcherProtocol,
    uiState: WorkspaceUIState,
    documentReference: DocumentReference,
    landscapeRuntime: ProgramRuntime,
    portraitRuntime: ProgramRuntime
  ) {
    self.uiState = uiState
    self.dispatcher = dispatcher
    self.contentPane = WorkspaceContent(
      deviceRegistry: deviceRegistry, uiState: uiState, appletData: appletData,
      landscapeRuntime: landscapeRuntime, portraitRuntime: portraitRuntime)

    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 1062, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false)

    self.representedURL = url
    self.title = url.deletingPathExtension().lastPathComponent
    self.isReleasedWhenClosed = false

    let sidebarView = WorkspaceSidebar(
      uiState: uiState, deviceRegistry: deviceRegistry, appletData: appletData
    )
    .environment(\.workspaceDispatcher, dispatcher)

    let contentView =
      contentPane
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

    let splitViewController = PaneSplitViewController(
      sidebar: sidebarController, content: contentController, inspector: inspectorController,
      sidebarCanCollapse: true)

    self.contentViewController = splitViewController
    self.titleVisibility = .visible
    self.toolbarStyle = .unified
    let toolbar = NSToolbar(identifier: "WorkspaceV4Toolbar.AppKit.v1")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    self.toolbar = toolbar
    // Installing the content controller replaces the initial size with its fitting size.
    let toolbarHeight = frame.height - contentLayoutRect.height
    self.setFrame(
      NSRect(origin: frame.origin, size: NSSize(width: 1062, height: 700 + toolbarHeight)),
      display: false)

    splitViewController.setInitialWidths(sidebar: 240, content: 480)

    self.center()
  }

  public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      .init("workspace.sidebar"), .sidebarTrackingSeparator,
      .init("workspace.stopOutput"), .init("workspace.toggleOutput"),
      .flexibleSpace,
      .inspectorTrackingSeparator, .flexibleSpace, .init("workspace.inspector"),
    ]
  }

  public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  public func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.target = contentViewController
    switch identifier.rawValue {
    case "workspace.sidebar":
      item.label = "Sidebar"
      item.paletteLabel = "Sidebar"
      item.toolTip = "Show or hide the Sidebar"
      item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar")
      item.action = #selector(PaneSplitViewController.toggleSidebar(_:))
    case "workspace.stopOutput":
      configureOutputItem(item)
      item.isNavigational = true
      item.target = self
      item.action = #selector(stopOutput(_:))
    case "workspace.toggleOutput":
      configureOutputItem(item)
      item.isNavigational = true
      item.target = self
      item.action = #selector(toggleOutput(_:))
    case "workspace.inspector":
      item.label = "Inspector"
      item.paletteLabel = "Inspector"
      item.toolTip = "Show or hide the Inspector"
      item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Inspector")
      item.action = #selector(PaneSplitViewController.toggleInspector(_:))
    default:
      return nil
    }
    return item
  }

  private func configureOutputItem(_ item: NSToolbarItem) {
    let isStop = item.itemIdentifier.rawValue == "workspace.stopOutput"
    let isRunning = uiState.recordingState == .recording
    let label = isStop ? "Stop Output" : (isRunning ? "Pause Output" : "Start Output")
    let symbol = isStop ? "stop.fill" : (isRunning ? "pause.fill" : "play.fill")
    item.label = label
    item.paletteLabel = label
    item.toolTip = label
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    item.isEnabled = validateToolbarItem(item)
  }

  func updateOutputToolbar() {
    for item in toolbar?.items ?? [] where item.target === self {
      configureOutputItem(item)
    }
  }

  public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
    switch item.itemIdentifier.rawValue {
    case "workspace.stopOutput": uiState.recordingState.canStop
    case "workspace.toggleOutput":
      uiState.recordingState.canStart || uiState.recordingState == .recording
    default: true
    }
  }

  @objc private func stopOutput(_ sender: Any?) {
    guard uiState.recordingState.canStop else { return }
    Task { await dispatcher.stopOutput() }
  }

  @objc private func toggleOutput(_ sender: Any?) {
    let state = uiState.recordingState
    guard state.canStart || state == .recording else { return }
    Task {
      if state == .recording {
        await dispatcher.pauseOutput()
      } else {
        do { try await dispatcher.startOutput() } catch {
          uiState.outputFailureMessage = error.localizedDescription
        }
      }
    }
  }

}
