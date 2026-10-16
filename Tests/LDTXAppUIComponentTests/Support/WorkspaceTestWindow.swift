// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletUI
import SwiftUI

@MainActor
final class WorkspaceTestWindow: NSWindow {
  let content: WorkspaceViewState
  let workspaceDocument: (any WorkspaceDocumentContext)?
  init(content: WorkspaceViewState, document: (any WorkspaceDocumentContext)? = nil) {
    self.content = content
    workspaceDocument = document
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 1062, height: 700),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    let host = NSHostingController(rootView: WorkspaceRootView(state: content))
    host.sizingOptions = []
    host.sceneBridgingOptions = [.toolbars]
    contentViewController = host
    setContentSize(NSSize(width: 1062, height: 700))
    content.didAttachWindow?(self)
  }
  var contentPane: WorkspaceContentPane { WorkspaceRootView(state: content).contentPane }
  var stateService: WorkspaceStateService { content.stateService }
  func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
    item.menuFormRepresentation?.isEnabled ?? false
  }
  func runInference() { content.runInference() }
  func captureScreenshots() { content.captureScreenshots() }
  func toggleOutput() { content.toggleOutput() }
  func stopOutput() { content.stopOutput() }
  override func close() {
    content.tearDown()
    super.close()
  }
}

// Test-only adapter for the AppKit document fixtures.
// swift-format-ignore: AvoidRetroactiveConformances
extension NSDocument: @retroactive WorkspaceDocumentContext {}
