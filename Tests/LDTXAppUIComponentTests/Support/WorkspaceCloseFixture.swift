// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceBundleFormat
import Testing

@MainActor
final class WorkspaceCloseFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let document: WorkspaceDocument
  let url: URL
  let window: NSWindow

  init() async throws {
    _ = UIComponentTestEnvironment.documentController
    _ = NSApplication.shared
    let document = WorkspaceDocument()
    let url = root.appendingPathComponent("Close.ldtxworkspace")
    do {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        document.save(to: url, ofType: "tokyo.kaito.ldtx.workspace", for: .saveAsOperation) {
          error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
      }
      UIComponentTestEnvironment.documentController.addDocument(document)
      document.makeWindowControllers()
      let window = try #require(document.windowControllers.first?.window)
      window.orderFront(nil)
      document.storeService.definition.displayName = "Pending"
      self.document = document
      self.url = url
      self.window = window
    } catch {
      document.close()
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }

  func cleanup() {
    document.close()
    try? FileManager.default.removeItem(at: root)
  }
}

@MainActor
final class WorkspaceCloseProbe: NSObject {
  var result: Bool?
  @objc func document(
    _ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?
  ) {
    result = shouldClose
  }
}
