// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletUI

@MainActor
final class WorkspaceTestWindow: NSWindow {
  let content: WorkspaceViewController
  let workspaceDocument: (any WorkspaceDocumentContext)?
  init(content: WorkspaceViewController, document: (any WorkspaceDocumentContext)? = nil) {
    self.content = content
    workspaceDocument = document
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 1062, height: 700),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    contentViewController = content
    setContentSize(NSSize(width: 1062, height: 700))
    content.viewDidAppear()
  }
  var splitViewController: NSSplitViewController { content.splitViewController }
  var contentPane: WorkspaceContentPane { content.contentPane }
  var stateService: WorkspaceStateService { content.stateService }
  func validateToolbarItem(_ item: NSToolbarItem) -> Bool { content.validateToolbarItem(item) }
  var screenshotResultPopover: NSPopover { content.screenshotResultPopover }
  func runInference() { content.runInference() }
  func captureScreenshots() { content.captureScreenshots() }
  func toggleOutput() { content.toggleOutput() }
  func stopOutput() { content.stopOutput() }
  override func close() {
    content.tearDown()
    super.close()
  }
}

extension NSDocument: @retroactive WorkspaceDocumentContext {}
