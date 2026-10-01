// SPDX-FileCopyrightText: 2026 Kaito Udagawa
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

@MainActor
public final class LauncherApplet: NSWindowController {
  public init() {
    let window = NSWindow(
      contentViewController: NSHostingController(
        rootView: LauncherContent()))
    window.title = "LDTX"
    window.setContentSize(NSSize(width: 420, height: 260))
    window.center()
    window.isReleasedWhenClosed = false
    window.styleMask.remove(.resizable)
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
