// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXAppKitUI
import SwiftUI
import Testing

@MainActor
struct PaneSplitViewTests {
  @Test func sidebarTogglePreservesWidthAndWindow() {
    _ = NSApplication.shared
    let split = PaneSplitViewController(
      sidebar: paneHost(Text("Sidebar")), content: paneHost(Text("Content")),
      inspector: paneHost(Text("Inspector")), sidebarCanCollapse: true)
    let window = PaneWindow(contentViewController: split)
    window.setContentSize(NSSize(width: 1200, height: 700))
    window.orderFront(nil)
    defer { window.close() }
    split.setInitialWidths(sidebar: 280, content: 580)
    let frame = window.frame
    for _ in 0..<3 {
      split.toggleSidebar(nil)
      split.view.layoutSubtreeIfNeeded()
      #expect(split.splitViewItems[0].isCollapsed)
      #expect(window.frame == frame)
      split.toggleSidebar(nil)
      split.view.layoutSubtreeIfNeeded()
      #expect(!split.splitViewItems[0].isCollapsed)
      #expect(abs(split.splitView.arrangedSubviews[0].frame.width - 280) < 1)
      #expect(window.frame == frame)
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

  @Test func dividerMovementStaysInsideWindow() async {
    _ = NSApplication.shared
    let split = PaneSplitViewController(
      sidebar: paneHost(Text("Sidebar").frame(maxWidth: .infinity, maxHeight: .infinity)),
      content: paneHost(Text("Content").frame(maxWidth: .infinity, maxHeight: .infinity)),
      inspector: paneHost(Text("Inspector").frame(maxWidth: .infinity, maxHeight: .infinity)))
    let window = NSWindow(contentViewController: split)
    window.setContentSize(NSSize(width: 1200, height: 700))
    window.orderFront(nil)
    defer { window.close() }
    split.setInitialWidths(sidebar: 240, content: 620)
    await Task.yield()
    let initialFrame = window.frame
    for position: CGFloat in [400, 900, 5000, 0, -1000, 240] {
      split.splitView.setPosition(position, ofDividerAt: 0)
      split.view.layoutSubtreeIfNeeded()
      #expect(window.frame == initialFrame)
      #expect(!split.splitViewItems[0].isCollapsed)
      #expect(split.splitViewItems[0].viewController.view.frame.width > 0)
      for item in split.splitViewItems where !item.isCollapsed {
        #expect(item.viewController.view.frame.minX >= -1)
        #expect(item.viewController.view.frame.maxX <= split.splitView.bounds.width + 1)
      }
    }
    split.splitView.setPosition(240, ofDividerAt: 0)
    for position: CGFloat in [300, 900, 5000, -1000, 800] {
      split.splitView.setPosition(position, ofDividerAt: 1)
      split.view.layoutSubtreeIfNeeded()
      #expect(window.frame == initialFrame)
      #expect(!split.splitViewItems[0].isCollapsed)
      #expect(
        split.splitViewItems[2].viewController.view.frame.maxX <= split.splitView.bounds.width + 1)
    }
    split.toggleInspector(nil)
    #expect(split.splitViewItems[2].isCollapsed)
    split.restoreWidths(sidebar: 300, inspector: 340)
    #expect(abs(split.splitView.arrangedSubviews[0].frame.width - 300) < 1)
    #expect(!split.splitViewItems[0].isCollapsed)
    split.toggleInspector(nil)
    #expect(!split.splitViewItems[2].isCollapsed)
  }
}
