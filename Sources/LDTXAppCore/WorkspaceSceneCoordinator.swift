// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

struct WorkspaceWindowReader: NSViewRepresentable {
  let windowChanged: @MainActor (NSWindow?) -> Void

  func makeNSView(context: Context) -> WorkspaceWindowObservingView {
    WorkspaceWindowObservingView(windowChanged: windowChanged)
  }

  func updateNSView(_ nsView: WorkspaceWindowObservingView, context: Context) {
    nsView.windowChanged = windowChanged
    nsView.reportWindow()
  }
}

@MainActor
final class WorkspaceWindowObservingView: NSView {
  var windowChanged: @MainActor (NSWindow?) -> Void

  init(windowChanged: @escaping @MainActor (NSWindow?) -> Void) {
    self.windowChanged = windowChanged
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    reportWindow()
  }

  func reportWindow() {
    windowChanged(window)
  }
}
