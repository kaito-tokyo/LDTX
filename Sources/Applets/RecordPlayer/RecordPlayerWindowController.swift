// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

@MainActor
public final class RecordPlayerWindowController: NSWindowController {
  init(model: LDTXRecordPlayerModel, document: RecordPlayerDocument) {
    let window = NSWindow(
      contentRect: .zero,
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.contentViewController = NSHostingController(
      rootView: LDTXRecordPlayerView(
        model: model, document: document,
        requestClose: { [weak window] in window?.performClose(nil) }))
    window.setContentSize(NSSize(width: 960, height: 600))
    window.contentMinSize = NSSize(width: 640, height: 400)
    window.center()
    window.isReleasedWhenClosed = false
    window.isRestorable = true
    window.toolbarStyle = .unified
    window.setFrameAutosaveName("Recording.AppKit.v1")
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}
