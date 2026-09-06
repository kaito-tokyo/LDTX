// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit

@MainActor
public final class PaneWindow: NSWindow {
  public var restorationURL: URL?
  public var restorationKind = ""

  public override func encodeRestorableState(with coder: NSCoder) {
    super.encodeRestorableState(with: coder)
    encodePaneState(with: coder)
  }

  func encodePaneState(with coder: NSCoder) {
    coder.encode(restorationURL as NSURL?, forKey: "LDTX.AppKit.v1.url")
    coder.encode(restorationKind as NSString, forKey: "LDTX.AppKit.v1.kind")
    if let split = contentViewController as? PaneSplitViewController {
      coder.encode(
        Double(split.expandedSidebarThickness),
        forKey: "LDTX.AppKit.v1.sidebarWidth")
      coder.encode(
        Double(split.expandedInspectorThickness),
        forKey: "LDTX.AppKit.v1.inspectorWidth")
      coder.encode(split.splitViewItems[0].isCollapsed, forKey: "LDTX.AppKit.v1.sidebarCollapsed")
      coder.encode(split.splitViewItems[2].isCollapsed, forKey: "LDTX.AppKit.v1.inspectorCollapsed")
    }
  }

  public override func restoreState(with coder: NSCoder) {
    super.restoreState(with: coder)
    if let split = contentViewController as? PaneSplitViewController,
      coder.containsValue(forKey: "LDTX.AppKit.v1.sidebarWidth")
    {
      if split.splitViewItems[0].canCollapse {
        split.splitViewItems[0].isCollapsed = coder.decodeBool(
          forKey: "LDTX.AppKit.v1.sidebarCollapsed")
      }
      split.splitViewItems[2].isCollapsed = coder.decodeBool(
        forKey: "LDTX.AppKit.v1.inspectorCollapsed")
      let sidebar = coder.decodeDouble(forKey: "LDTX.AppKit.v1.sidebarWidth")
      let inspector = coder.decodeDouble(forKey: "LDTX.AppKit.v1.inspectorWidth")
      if sidebar.isFinite && inspector.isFinite {
        split.restoreWidths(sidebar: CGFloat(max(0, sidebar)), inspector: CGFloat(max(0, inspector)))
      }
    }
    if let screen = screen ?? NSScreen.main {
      let visible = screen.visibleFrame
      var frame = frame
      frame.size.width = min(frame.width, visible.width)
      frame.size.height = min(frame.height, visible.height)
      frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
      frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
      setFrame(frame, display: false)
    }
  }
}
