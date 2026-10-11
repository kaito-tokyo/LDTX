// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit

final class WorkspaceToolbarCoordinator: NSObject, NSToolbarDelegate {
  let toolbar: NSToolbar
  private let sidebarItem: NSToolbarItem
  private let stopOutputItem: NSToolbarItem
  private let startPauseOutputItem: NSToolbarItem
  private let captureScreenshotsItem: NSToolbarItem
  private let runInferenceItem: NSToolbarItem
  private let toggleInspectorItem: NSToolbarItem

  @MainActor
  override init() {
    toolbar = NSToolbar(identifier: "workspace")
    sidebarItem = NSToolbarItem(itemIdentifier: Identifiers.sidebar.itemIdentifier)
    stopOutputItem = NSToolbarItem(itemIdentifier: Identifiers.stopOutput.itemIdentifier)
    startPauseOutputItem = NSToolbarItem(itemIdentifier: Identifiers.startPauseOutput.itemIdentifier)
    captureScreenshotsItem = NSToolbarItem(itemIdentifier: Identifiers.captureScreenshots.itemIdentifier)
    runInferenceItem = NSToolbarItem(itemIdentifier: Identifiers.runInference.itemIdentifier)
    toggleInspectorItem = NSToolbarItem(itemIdentifier: Identifiers.toggleInspector.itemIdentifier)
    super.init()
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      Identifiers.sidebar.itemIdentifier,
      Identifiers.stopOutput.itemIdentifier,
      Identifiers.startPauseOutput.itemIdentifier,
      Identifiers.captureScreenshots.itemIdentifier,
      .flexibleSpace,
      .inspectorTrackingSeparator,
      .flexibleSpace,
      Identifiers.runInference.itemIdentifier,
      Identifiers.toggleInspector.itemIdentifier,
    ]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    return switch identifier {
    case sidebarItem.itemIdentifier: sidebarItem
    case stopOutputItem.itemIdentifier: stopOutputItem
    case startPauseOutputItem.itemIdentifier: startPauseOutputItem
    case captureScreenshotsItem.itemIdentifier: captureScreenshotsItem
    case runInferenceItem.itemIdentifier: runInferenceItem
    case toggleInspectorItem.itemIdentifier: toggleInspectorItem
    default: nil
    }
  }

  @MainActor
  func configureToolbar(target: WorkspaceWindow) {
    sidebarItem.label = "Toggle Sidebar"
    sidebarItem.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
    sidebarItem.target = target
    sidebarItem.action = #selector(WorkspaceWindow.toggleSidebar)
    sidebarItem.autovalidates = false

    stopOutputItem.label = "Stop Output"
    stopOutputItem.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
    stopOutputItem.target = target
    stopOutputItem.action = #selector(WorkspaceWindow.stopOutput)
    stopOutputItem.autovalidates = false

    startPauseOutputItem.label = "Start Output"
    startPauseOutputItem.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
    startPauseOutputItem.target = target
    startPauseOutputItem.action = #selector(WorkspaceWindow.toggleOutput)
    startPauseOutputItem.autovalidates = false

    captureScreenshotsItem.label = "Capture Screenshot(s)"
    captureScreenshotsItem.image = NSImage(systemSymbolName: "camera", accessibilityDescription: nil)
    captureScreenshotsItem.target = target
    captureScreenshotsItem.action = #selector(WorkspaceWindow.captureScreenshots)
    captureScreenshotsItem.autovalidates = false

    runInferenceItem.label = "Run Inference"
    runInferenceItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
    runInferenceItem.target = target
    runInferenceItem.action = #selector(WorkspaceWindow.runInference)
    runInferenceItem.autovalidates = false

    toggleInspectorItem.label = "Toggle Inspector"
    toggleInspectorItem.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
    toggleInspectorItem.target = target
    toggleInspectorItem.action = #selector(WorkspaceWindow.toggleInspector)
    toggleInspectorItem.autovalidates = false

    toolbar.autosavesConfiguration = false
    toolbar.allowsUserCustomization = false
    toolbar.displayMode = .iconOnly
    toolbar.delegate = self
  }

  @MainActor
  func updateToolbarItems(
    canRunInference: Bool, canStopOutput: Bool, canStartOutput: Bool, isRecording: Bool
  ) {
    runInferenceItem.isEnabled = canRunInference
    stopOutputItem.isEnabled = canStopOutput
    startPauseOutputItem.label = isRecording ? "Pause Output" : "Start Output"
    startPauseOutputItem.image = NSImage(
      systemSymbolName: isRecording ? "pause.fill" : "play.fill",
      accessibilityDescription: nil)
    startPauseOutputItem.isEnabled = canStartOutput || isRecording
  }

  @MainActor
  func showPendingEditsPopover(_ popover: NSPopover) {
    popover.show(relativeTo: toggleInspectorItem)
  }

  @MainActor
  func showScreenshotResultPopover(_ popover: NSPopover) {
    popover.show(relativeTo: captureScreenshotsItem)
  }

  enum Identifiers: String {
    case sidebar = "workspace.toggleSidebar"
    case stopOutput = "workspace.stopOutput"
    case startPauseOutput = "workspace.startPauseOutput"
    case captureScreenshots = "workspace.captureScreenshots"
    case runInference = "workspace.runInference"
    case toggleInspector = "workspace.toggleInspector"

    var itemIdentifier: NSToolbarItem.Identifier {
      NSToolbarItem.Identifier(self.rawValue)
    }
  }
}
