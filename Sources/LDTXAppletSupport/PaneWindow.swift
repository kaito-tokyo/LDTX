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

  public static let legacyURL = "LDTX.AppKit.v1.url"
  public static let legacySidebarWidth = "LDTX.AppKit.v1.sidebarWidth"
  public static let legacyInspectorWidth = "LDTX.AppKit.v1.inspectorWidth"
  public static let legacySidebarCollapsed = "LDTX.AppKit.v1.sidebarCollapsed"
  public static let legacyInspectorCollapsed = "LDTX.AppKit.v1.inspectorCollapsed"

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
    coder.encode(restorationURL as NSURL?, forKey: LDTXAppKitRestorationKeys.legacyURL)
    coder.encode(restorationKind as NSString, forKey: LDTXAppKitRestorationKeys.kind)
    if let split = contentViewController as? PaneSplitViewController {
      coder.encode(
        Double(split.expandedSidebarThickness),
        forKey: LDTXAppKitRestorationKeys.sidebarWidth)
      coder.encode(
        Double(split.expandedSidebarThickness),
        forKey: LDTXAppKitRestorationKeys.legacySidebarWidth)
      coder.encode(
        Double(split.expandedInspectorThickness),
        forKey: LDTXAppKitRestorationKeys.inspectorWidth)
      coder.encode(
        Double(split.expandedInspectorThickness),
        forKey: LDTXAppKitRestorationKeys.legacyInspectorWidth)
      coder.encode(
        split.splitViewItems[0].isCollapsed, forKey: LDTXAppKitRestorationKeys.sidebarCollapsed)
      coder.encode(
        split.splitViewItems[0].isCollapsed,
        forKey: LDTXAppKitRestorationKeys.legacySidebarCollapsed)
      coder.encode(
        split.splitViewItems[2].isCollapsed, forKey: LDTXAppKitRestorationKeys.inspectorCollapsed)
      coder.encode(
        split.splitViewItems[2].isCollapsed,
        forKey: LDTXAppKitRestorationKeys.legacyInspectorCollapsed)
    }
  }

  public override func restoreState(with coder: NSCoder) {
    super.restoreState(with: coder)
    let sidebarWidthKey =
      coder.containsValue(
        forKey: LDTXAppKitRestorationKeys.sidebarWidth)
      ? LDTXAppKitRestorationKeys.sidebarWidth
      : LDTXAppKitRestorationKeys.legacySidebarWidth
    let inspectorWidthKey =
      coder.containsValue(
        forKey: LDTXAppKitRestorationKeys.inspectorWidth)
      ? LDTXAppKitRestorationKeys.inspectorWidth
      : LDTXAppKitRestorationKeys.legacyInspectorWidth
    let sidebarCollapsedKey =
      coder.containsValue(
        forKey: LDTXAppKitRestorationKeys.sidebarCollapsed)
      ? LDTXAppKitRestorationKeys.sidebarCollapsed
      : LDTXAppKitRestorationKeys.legacySidebarCollapsed
    let inspectorCollapsedKey =
      coder.containsValue(
        forKey: LDTXAppKitRestorationKeys.inspectorCollapsed)
      ? LDTXAppKitRestorationKeys.inspectorCollapsed
      : LDTXAppKitRestorationKeys.legacyInspectorCollapsed
    if let split = contentViewController as? PaneSplitViewController,
      coder.containsValue(forKey: sidebarWidthKey)
    {
      if split.splitViewItems[0].canCollapse {
        split.splitViewItems[0].isCollapsed = coder.decodeBool(
          forKey: sidebarCollapsedKey)
      }
      split.splitViewItems[2].isCollapsed = coder.decodeBool(forKey: inspectorCollapsedKey)
      let sidebar = coder.decodeDouble(forKey: sidebarWidthKey)
      let inspector = coder.decodeDouble(forKey: inspectorWidthKey)
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
