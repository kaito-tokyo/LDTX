// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXDeviceRegistry
import LDTXWorkspaceAppletInterface
import LDTXWorkspaceAppletUI
import Observation
import SwiftUI

public final class WorkspaceWindow: NSWindow, NSToolbarDelegate, NSToolbarItemValidation {
  let contentPane: WorkspaceContentPane
  private let storeService: WorkspaceStoreService

  init(
    url: URL,
    deviceRegistry: DeviceRegistryService,
    appletData: WorkspaceAppletData,
    storeService: WorkspaceStoreService,
    documentReference: DocumentReference,
    pairedPreview: ProgramCanvasPairedPreview
  ) {
    self.storeService = storeService
    storeService.appletData = appletData
    storeService.documentReference = documentReference
    self.contentPane = WorkspaceContentPane(
      storeService: storeService,
      pairedPreview: pairedPreview)

    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 1062, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false)

    self.representedURL = url
    self.title = url.deletingPathExtension().lastPathComponent
    self.isReleasedWhenClosed = false

    let sidebarView = WorkspaceSidebar(
      storeService: storeService, deviceRegistry: deviceRegistry, appletData: appletData
    )

    let inspectorView = WorkspaceInspectorContainer(
      deviceRegistry: deviceRegistry,
      storeService: storeService,
      appletData: appletData
    )

    let sidebarController = NSHostingController(
      rootView: sidebarView.environment(\.documentReference, documentReference))
    sidebarController.sizingOptions = [.minSize]

    let inspectorController = NSHostingController(
      rootView: inspectorView.environment(\.documentReference, documentReference))
    inspectorController.sizingOptions = [.minSize]

    let splitViewController = PaneSplitViewController(
      sidebar: sidebarController, content: contentPane, inspector: inspectorController,
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
    contentPane.configureAfterEstablished()

    self.center()
  }

  public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      .init("workspace.sidebar"), .sidebarTrackingSeparator,
      .init("workspace.stopOutput"), .init("workspace.toggleOutput"),
      .init("workspace.captureScreenshots"), .init("workspace.openScreenshotsFolder"),
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
    case "workspace.captureScreenshots":
      item.label = "Capture Screenshot(s)"
      item.paletteLabel = item.label
      item.toolTip = item.label
      item.image = NSImage(systemSymbolName: "camera", accessibilityDescription: item.label)
      item.target = self
      item.action = #selector(captureScreenshots(_:))
      item.isEnabled = validateToolbarItem(item)
    case "workspace.openScreenshotsFolder":
      item.label = "Open Screenshots Folder"
      item.paletteLabel = item.label
      item.toolTip = item.label
      item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: item.label)
      item.target = self
      item.action = #selector(openScreenshotsFolder(_:))
      item.isEnabled = validateToolbarItem(item)
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
    let isRunning = storeService.recordingState == .recording
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
      switch item.itemIdentifier.rawValue {
      case "workspace.stopOutput", "workspace.toggleOutput": configureOutputItem(item)
      default: item.isEnabled = validateToolbarItem(item)
      }
    }
  }

  public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
    switch item.itemIdentifier.rawValue {
    case "workspace.stopOutput": storeService.recordingState.canStop
    case "workspace.toggleOutput":
      storeService.recordingState.canStart || storeService.recordingState == .recording
    case "workspace.captureScreenshots", "workspace.openScreenshotsFolder":
      storeService.isOutputActive && storeService.isLocalRecording
    default: true
    }
  }

  @objc private func captureScreenshots(_ sender: Any?) {
    guard storeService.isOutputActive && storeService.isLocalRecording else { return }
    do { _ = try storeService.captureScreenshots() } catch {
      storeService.outputFailureMessage = error.localizedDescription
    }
  }

  @objc private func openScreenshotsFolder(_ sender: Any?) {
    guard storeService.isOutputActive && storeService.isLocalRecording else { return }
    storeService.openScreenshotsDirectory()
  }

  @objc private func stopOutput(_ sender: Any?) {
    guard storeService.recordingState.canStop else { return }
    Task { await storeService.stopOutput() }
  }

  @objc private func toggleOutput(_ sender: Any?) {
    let state = storeService.recordingState
    guard state.canStart || state == .recording else { return }
    Task {
      if state == .recording {
        await storeService.pauseOutput()
      } else {
        do { try await storeService.startOutput() } catch {
          storeService.outputFailureMessage = error.localizedDescription
        }
      }
    }
  }

}
