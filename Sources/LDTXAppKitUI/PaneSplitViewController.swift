// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// Owns the native split. Hosted content supplies its natural minimum size.
@MainActor
public final class PaneSplitViewController: NSSplitViewController {
  public private(set) var expandedSidebarThickness: CGFloat = 240
  public private(set) var expandedInspectorThickness: CGFloat = 340
  public init(
    sidebar: NSViewController, content: NSViewController, inspector: NSViewController,
    sidebarCanCollapse: Bool = false, inspectorMaximum: CGFloat = 480
  ) {
    super.init(nibName: nil, bundle: nil)
    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    sidebarItem.canCollapse = sidebarCanCollapse
    sidebarItem.canCollapseFromWindowResize = false
    sidebarItem.holdingPriority = .init(260)
    let contentItem = NSSplitViewItem(viewController: content)
    contentItem.holdingPriority = .init(250)
    let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
    inspectorItem.canCollapse = true
    inspectorItem.canCollapseFromWindowResize = false
    inspectorItem.maximumThickness = inspectorMaximum
    inspectorItem.holdingPriority = .init(260)
    for item in [sidebarItem, contentItem, inspectorItem] {
      item.automaticallyAdjustsSafeAreaInsets = false
      addSplitViewItem(item)
    }
    NotificationCenter.default.addObserver(
      self, selector: #selector(layoutChanged),
      name: NSSplitView.didResizeSubviewsNotification, object: splitView)
  }

  @objc private func layoutChanged(_ notification: Notification) {
    if splitViewItems.count == 3, !splitViewItems[2].isCollapsed, splitView.arrangedSubviews.count == 3 {
      let thickness = splitView.arrangedSubviews[2].frame.width
      if thickness > 0 { expandedInspectorThickness = thickness }
    }
    if splitViewItems.count == 3, !splitViewItems[0].isCollapsed {
      let thickness = splitView.arrangedSubviews[0].frame.width
      if thickness > 0 { expandedSidebarThickness = thickness }
    }
    view.window?.invalidateRestorableState()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  public func setInitialWidths(sidebar: CGFloat, content: CGFloat) {
    view.layoutSubtreeIfNeeded()
    if !splitViewItems[0].isCollapsed {
      splitView.setPosition(sidebar, ofDividerAt: 0)
    }
    if !splitViewItems[2].isCollapsed {
      splitView.setPosition(sidebar + content + splitView.dividerThickness, ofDividerAt: 1)
    }
  }

  public func restoreWidths(sidebar: CGFloat, inspector: CGFloat) {
    view.layoutSubtreeIfNeeded()
    if sidebar > 0 { expandedSidebarThickness = sidebar }
    if inspector > 0 { expandedInspectorThickness = inspector }
    if !splitViewItems[0].isCollapsed { splitView.setPosition(sidebar, ofDividerAt: 0) }
    if !splitViewItems[2].isCollapsed {
      splitView.setPosition(
        splitView.bounds.width - inspector - splitView.dividerThickness, ofDividerAt: 1)
    }
  }

  @objc public override func toggleSidebar(_ sender: Any?) {
    guard splitViewItems[0].canCollapse else { return }
    let thickness = expandedSidebarThickness
    splitViewItems[0].isCollapsed.toggle()
    if !splitViewItems[0].isCollapsed {
      view.layoutSubtreeIfNeeded()
      splitView.setPosition(thickness, ofDividerAt: 0)
    }
    view.window?.invalidateRestorableState()
  }

  @objc public override func toggleInspector(_ sender: Any?) {
    let thickness = expandedInspectorThickness
    splitViewItems[2].isCollapsed.toggle()
    if !splitViewItems[2].isCollapsed {
      view.layoutSubtreeIfNeeded()
      splitView.setPosition(
        splitView.bounds.width - thickness - splitView.dividerThickness, ofDividerAt: 1)
    }
    view.window?.invalidateRestorableState()
  }

  public override func splitView(
    _ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat {
    let proposed = proposedPosition
    // Use AppKit's natural limits, additionally bounding movement to the current window.
    let lower = splitView.minPossiblePositionOfDivider(at: dividerIndex)
    let upper = min(
      splitView.maxPossiblePositionOfDivider(at: dividerIndex), splitView.bounds.width)
    return min(max(proposed, lower), max(lower, upper))
  }
}

@MainActor
public func paneHost<Content: View>(_ content: Content) -> NSHostingController<Content> {
  let host = NSHostingController(rootView: content)
  host.sizingOptions = [.minSize]
  return host
}
