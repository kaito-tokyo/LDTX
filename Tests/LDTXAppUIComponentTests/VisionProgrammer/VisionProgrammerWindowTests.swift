// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXVisionProgrammerApplet
import SwiftUI
import Testing

extension AppUIComponentTestSuite.Shard2 {
  @Suite struct VisionProgrammerWindowTests {
    @Test(
      "LUB-1073: Vision Programmer lays out in a directly hosted window",
      .timeLimit(.minutes(1)))
    @MainActor
    func laysOutInHostedWindow() async {
      let hosting = NSHostingView(rootView: VisionProgrammerView())
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
        styleMask: .titled, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.setContentSize(NSSize(width: 700, height: 500))
      defer { window.close() }
      window.contentView = hosting
      window.makeKeyAndOrderFront(nil)

      hosting.layoutSubtreeIfNeeded()
      #expect(window.isVisible)
      #expect(hosting.window === window)
      #expect(hosting.frame.width > 0)
      #expect(hosting.frame.height > 0)
    }
  }
}
