// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import SwiftUI
import Testing

@Suite
@MainActor
struct PaneSplitViewControllerUnitTestSuite {
  @Test func sidebarToggleRestoresExpandedWidth() {
    _ = NSApplication.shared
    let split = PaneSplitViewController(
      sidebar: paneHost(Text("Sidebar")), content: paneHost(Text("Content")),
      inspector: paneHost(Text("Inspector")), sidebarCanCollapse: true)
    let window = PaneWindow(contentViewController: split)
    window.setContentSize(NSSize(width: 1200, height: 700))
    window.orderFront(nil)
    defer { window.close() }
    split.setInitialWidths(sidebar: 280, content: 580)
    for _ in 0..<3 {
      split.toggleSidebar(nil)
      split.view.layoutSubtreeIfNeeded()
      #expect(split.splitViewItems[0].isCollapsed)
      split.toggleSidebar(nil)
      split.view.layoutSubtreeIfNeeded()
      #expect(!split.splitViewItems[0].isCollapsed)
      #expect(abs(split.splitView.arrangedSubviews[0].frame.width - 280) < 1)
    }
    #expect(!split.splitViewItems[0].canCollapseFromWindowResize)
  }

  @Test func paneWidthsArchiveAsNumbers() throws {
    _ = NSApplication.shared
    let split = PaneSplitViewController(
      sidebar: paneHost(Text("Sidebar")), content: paneHost(Text("Content")),
      inspector: paneHost(Text("Inspector")))
    let window = PaneWindow(contentViewController: split)
    window.setContentSize(NSSize(width: 1200, height: 700))
    window.orderFront(nil)
    defer { window.close() }
    split.setInitialWidths(sidebar: 300, content: 560)
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    window.encodePaneState(with: coder)
    coder.finishEncoding()
    let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
    #expect(abs(decoder.decodeDouble(forKey: "LDTX.AppKit.v1.sidebarWidth") - 300) < 1)
    #expect(decoder.decodeDouble(forKey: "LDTX.AppKit.v1.inspectorWidth") > 0)
  }

  @Test func inspectorToggleChangesComponentState() {
    _ = NSApplication.shared
    let split = PaneSplitViewController(
      sidebar: paneHost(Text("Sidebar")), content: paneHost(Text("Content")),
      inspector: paneHost(Text("Inspector")))
    #expect(!split.splitViewItems[2].isCollapsed)
    split.toggleInspector(nil)
    #expect(split.splitViewItems[2].isCollapsed)
    split.toggleInspector(nil)
    #expect(!split.splitViewItems[2].isCollapsed)
  }
}
