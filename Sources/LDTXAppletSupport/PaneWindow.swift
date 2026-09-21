// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit

public enum LDTXAppKitRestorationKeys {
  public static let url = "tokyo.kaito.ldtx.LDTX.AppKit.v1.url"
  public static let kind = "tokyo.kaito.ldtx.LDTX.AppKit.v1.kind"
  public static let sidebarWidth = "tokyo.kaito.ldtx.LDTX.AppKit.v1.sidebarWidth"
  public static let inspectorWidth = "tokyo.kaito.ldtx.LDTX.AppKit.v1.inspectorWidth"
  public static let sidebarCollapsed = "tokyo.kaito.ldtx.LDTX.AppKit.v1.sidebarCollapsed"
  public static let inspectorCollapsed = "tokyo.kaito.ldtx.LDTX.AppKit.v1.inspectorCollapsed"

}

@MainActor
public final class PaneWindow: NSWindow {
  public var windowControllerOwner: NSWindowController?
  public var restorationURL: URL?
  public var restorationKind = ""

  public override func encodeRestorableState(with coder: NSCoder) {
    super.encodeRestorableState(with: coder)
    encodePaneState(with: coder)
  }

  public func encodePaneState(with coder: NSCoder) {
    coder.encode(restorationURL as NSURL?, forKey: LDTXAppKitRestorationKeys.url)
    coder.encode(restorationKind as NSString, forKey: LDTXAppKitRestorationKeys.kind)
    if let split = contentViewController as? PaneSplitViewController {
      coder.encode(
        Double(split.expandedSidebarThickness),
        forKey: LDTXAppKitRestorationKeys.sidebarWidth)
      coder.encode(
        Double(split.expandedInspectorThickness),
        forKey: LDTXAppKitRestorationKeys.inspectorWidth)
      coder.encode(
        split.splitViewItems[0].isCollapsed, forKey: LDTXAppKitRestorationKeys.sidebarCollapsed)
      coder.encode(
        split.splitViewItems[2].isCollapsed, forKey: LDTXAppKitRestorationKeys.inspectorCollapsed)
    }
  }

  public override func restoreState(with coder: NSCoder) {
    super.restoreState(with: coder)
    if let split = contentViewController as? PaneSplitViewController,
      coder.containsValue(forKey: LDTXAppKitRestorationKeys.sidebarWidth)
    {
      if split.splitViewItems[0].canCollapse {
        split.splitViewItems[0].isCollapsed = coder.decodeBool(
          forKey: LDTXAppKitRestorationKeys.sidebarCollapsed)
      }
      split.splitViewItems[2].isCollapsed = coder.decodeBool(
        forKey: LDTXAppKitRestorationKeys.inspectorCollapsed)
      let sidebar = coder.decodeDouble(forKey: LDTXAppKitRestorationKeys.sidebarWidth)
      let inspector = coder.decodeDouble(forKey: LDTXAppKitRestorationKeys.inspectorWidth)
      if sidebar.isFinite && inspector.isFinite {
        split.restoreWidths(
          sidebar: CGFloat(max(0, sidebar)), inspector: CGFloat(max(0, inspector)))
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
