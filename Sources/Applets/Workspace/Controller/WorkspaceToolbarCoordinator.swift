// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit

final class WorkspaceToolbarCoordinator: NSObject, NSToolbarDelegate {
  let toolbar: NSToolbar
  let sidebarItem: NSToolbarItem
  let stopOutputItem: NSToolbarItem
  let startPauseOutputItem: NSToolbarItem
  let captureScreenshotsItem: NSToolbarItem
  let runInferenceItem: NSToolbarItem
  let toggleInspectorItem: NSToolbarItem

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
