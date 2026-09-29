// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletController
import SwiftUI
import Testing

@Suite
@MainActor
struct WorkspaceWindowSystemTestSuite {
  @Test func placesHostedViewsInStandardSplitController() {
    _ = NSApplication.shared
    let url = URL(fileURLWithPath: "/tmp/WorkspaceWindow.ldtxworkspace")
    let sidebar = NSHostingController(rootView: Text("Sidebar"))
    let content = NSHostingController(rootView: Text("Content"))
    let inspector = NSHostingController(rootView: Text("Inspector"))
    let window = makeWorkspaceWindow(
      url: url, sidebar: sidebar, content: content, inspector: inspector)
    defer { window.close() }

    #expect(window.representedURL == url)
    #expect(window.contentViewController === window.splitViewController)
    #expect(window.splitViewController.splitViewItems.count == 3)
    #expect(window.splitViewController.splitViewItems[0].viewController === sidebar)
    #expect(window.splitViewController.splitViewItems[1].viewController === content)
    #expect(window.splitViewController.splitViewItems[2].viewController === inspector)
  }
}
