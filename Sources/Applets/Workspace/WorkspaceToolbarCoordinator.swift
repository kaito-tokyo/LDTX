// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit

@MainActor
final class WorkspaceToolbarCoordinator: NSObject, NSToolbarDelegate {
  let toolbar: NSToolbar
  let sidebarItem: NSToolbarItem
  let stopOutputItem: NSToolbarItem
  let startPauseOutputItem: NSToolbarItem
  let captureScreenshotsItem: NSToolbarItem
  let runInferenceItem: NSToolbarItem
  let toggleInspectorItem: NSToolbarItem
  let inspectorSeparatorItem = NSToolbarItem(itemIdentifier: .init("workspace.inspectorSeparator"))
  private let inspectorSpaceItem = NSToolbarItem(itemIdentifier: .init("workspace.inspectorSpace"))
  private let inspectorSeparator = InspectorToolbarSeparator()
  private let inspectorSpace = NSView()
  private var inspectorSpaceWidth: NSLayoutConstraint!
  private var inspectorWidth: CGFloat = 0

  @MainActor
  override init() {
    toolbar = NSToolbar(identifier: "workspace")
    sidebarItem = NSToolbarItem(itemIdentifier: Identifiers.sidebar.itemIdentifier)
    stopOutputItem = NSToolbarItem(itemIdentifier: Identifiers.stopOutput.itemIdentifier)
    startPauseOutputItem = NSToolbarItem(
      itemIdentifier: Identifiers.startPauseOutput.itemIdentifier)
    captureScreenshotsItem = NSToolbarItem(
      itemIdentifier: Identifiers.captureScreenshots.itemIdentifier)
    runInferenceItem = NSToolbarItem(itemIdentifier: Identifiers.runInference.itemIdentifier)
    toggleInspectorItem = NSToolbarItem(itemIdentifier: Identifiers.toggleInspector.itemIdentifier)
    super.init()
    inspectorSeparator.boxType = .separator
    inspectorSeparator.setAccessibilityLabel("Inspector toolbar separator")
    inspectorSeparatorItem.view = inspectorSeparator
    inspectorSpaceItem.view = inspectorSpace
    inspectorSeparator.translatesAutoresizingMaskIntoConstraints = false
    inspectorSpace.translatesAutoresizingMaskIntoConstraints = false
    inspectorSpaceWidth = inspectorSpace.widthAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      inspectorSeparator.widthAnchor.constraint(equalToConstant: 1),
      inspectorSeparator.heightAnchor.constraint(equalToConstant: 24),
      inspectorSpaceWidth,
      inspectorSpace.heightAnchor.constraint(equalToConstant: 1),
    ])
    inspectorSeparator.layoutChanged = { [weak self] in self?.synchronizeInspectorLayout() }
  }

  func updateInspectorWidth(_ width: CGFloat) {
    inspectorWidth = width
    inspectorSeparator.isHidden = width == 0
    synchronizeInspectorLayout()
  }

  private func synchronizeInspectorLayout() {
    guard inspectorWidth > 0 else {
      inspectorSpaceWidth.constant = 0
      return
    }
    guard let window = inspectorSeparator.window, let content = window.contentView else { return }
    let boundary = content.convert(content.bounds, to: nil).maxX - inspectorWidth
    let actual = inspectorSeparator.convert(inspectorSeparator.bounds, to: nil).midX
    let width = max(0, inspectorSpaceWidth.constant + actual - boundary)
    if abs(inspectorSpaceWidth.constant - width) > 0.5 {
      inspectorSpaceWidth.constant = width
    }
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      Identifiers.sidebar.itemIdentifier,
      Identifiers.stopOutput.itemIdentifier,
      Identifiers.startPauseOutput.itemIdentifier,
      Identifiers.captureScreenshots.itemIdentifier,
      .flexibleSpace,
      inspectorSeparatorItem.itemIdentifier,
      inspectorSpaceItem.itemIdentifier,
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
    case inspectorSeparatorItem.itemIdentifier: inspectorSeparatorItem
    case inspectorSpaceItem.itemIdentifier: inspectorSpaceItem
    default: nil
    }
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

private final class InspectorToolbarSeparator: NSBox {
  var layoutChanged: (() -> Void)?

  override func setFrameOrigin(_ newOrigin: NSPoint) {
    super.setFrameOrigin(newOrigin)
    scheduleLayoutChange()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    scheduleLayoutChange()
  }

  private func scheduleLayoutChange() {
    Task { @MainActor [weak self] in self?.layoutChanged?() }
  }
}
