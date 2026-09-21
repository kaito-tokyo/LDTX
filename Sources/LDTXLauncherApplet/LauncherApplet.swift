// SPDX-FileCopyrightText: 2026 Kaito Udagawa
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

@MainActor
public final class LauncherApplet: NSWindowController {
  public static func open(
    newWorkspace: @escaping () -> Void,
    openFile: @escaping () -> Void,
    completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
  ) {
    let applet = LauncherApplet(newWorkspace: newWorkspace, openFile: openFile)
    applet.showWindow(nil)
    applet.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    completionHandler(applet.window, nil)
  }

  public init(newWorkspace: @escaping () -> Void, openFile: @escaping () -> Void) {
    let window = NSWindow(
      contentViewController: NSHostingController(
        rootView: LauncherContent(newWorkspace: newWorkspace, openFile: openFile)))
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
