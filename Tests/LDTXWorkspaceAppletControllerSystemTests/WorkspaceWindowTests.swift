// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletController
import SwiftUI
import Testing

@Suite
@MainActor
struct WorkspaceWindowSystemTestSuite {
  @Test func createsThreeCollapsiblePanesAndRetainsWidths() {
    _ = NSApplication.shared
    let window = makeWindow()
    window.setContentSize(NSSize(width: 1200, height: 700))
    window.makeKeyAndOrderFront(nil)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    defer { window.close() }

    let split = window.splitViewController
    #expect(split.splitViewItems.count == 3)
    #expect(split.splitViewItems[0].canCollapse)
    #expect(split.splitViewItems[2].canCollapse)
    #expect(!split.splitViewItems[0].canCollapseFromWindowResize)
    #expect(!split.splitViewItems[2].canCollapseFromWindowResize)

    split.view.layoutSubtreeIfNeeded()
    let sidebarWidth = split.splitView.arrangedSubviews[0].frame.width
    let inspectorWidth = split.splitView.arrangedSubviews[2].frame.width
    #expect(abs(sidebarWidth - 240) < 1)
    #expect(abs(inspectorWidth - 340) < 1)

    window.toggleSidebar(nil)
    #expect(split.splitViewItems[0].isCollapsed)
    window.toggleSidebar(nil)
    #expect(!split.splitViewItems[0].isCollapsed)
    #expect(abs(split.splitView.arrangedSubviews[0].frame.width - sidebarWidth) < 1)

    window.toggleInspector(nil)
    #expect(window.isInspectorCollapsed)
    #expect(split.splitViewItems.count == 2)
    window.toggleInspector(nil)
    #expect(!window.isInspectorCollapsed)
    #expect(split.splitViewItems.count == 3)
    #expect(abs(split.splitView.arrangedSubviews[2].frame.width - inspectorWidth) < 1)
  }

  @Test func savesAndRestoresWorkspaceWindowState() throws {
    _ = NSApplication.shared
    let url = URL(fileURLWithPath: "/tmp/WorkspaceWindowSystemTest.ldtxworkspace")
    let original = makeWindow(url: url)
    original.setContentSize(NSSize(width: 1200, height: 700))
    original.makeKeyAndOrderFront(nil)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    defer { original.close() }
    original.toggleSidebar(nil)
    original.toggleInspector(nil)

    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    original.encodeWorkspacePaneState(with: archiver)
    archiver.finishEncoding()

    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
    #expect(
      unarchiver.decodeObject(
        of: NSURL.self, forKey: "tokyo.kaito.ldtx.LDTX.WorkspaceAppletController.v1.url")
        as URL? == url)
    #expect(!unarchiver.containsValue(forKey: "tokyo.kaito.ldtx.LDTX.AppKit.v1.url"))
    #expect(!unarchiver.containsValue(forKey: "LDTX.AppKit.v1.url"))
    #expect(unarchiver.decodeBool(forKey: "tokyo.kaito.ldtx.LDTX.AppKit.v1.sidebarCollapsed"))
    #expect(unarchiver.decodeBool(forKey: "tokyo.kaito.ldtx.LDTX.AppKit.v1.inspectorCollapsed"))
    #expect(unarchiver.decodeDouble(forKey: "tokyo.kaito.ldtx.LDTX.AppKit.v1.sidebarWidth") > 0)
    #expect(unarchiver.decodeDouble(forKey: "tokyo.kaito.ldtx.LDTX.AppKit.v1.inspectorWidth") > 0)

    let restored = makeWindow(url: url)
    defer { restored.close() }
    restored.restoreWorkspacePaneState(with: unarchiver)
    #expect(restored.representedURL == url)
    #expect(restored.splitViewController.splitViewItems[0].isCollapsed)
    #expect(restored.isInspectorCollapsed)
  }

  private func makeWindow(
    url: URL = URL(fileURLWithPath: "/tmp/WorkspaceWindow.ldtxworkspace")
  ) -> WorkspaceWindow {
    makeWorkspaceWindow(
      url: url,
      sidebar: NSHostingController(rootView: Text("Sidebar")),
      content: NSHostingController(rootView: Text("Content")),
      inspector: NSHostingController(rootView: Text("Inspector")))
  }
}
