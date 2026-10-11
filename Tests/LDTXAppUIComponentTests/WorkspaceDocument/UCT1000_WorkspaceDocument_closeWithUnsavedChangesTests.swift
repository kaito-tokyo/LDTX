// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceBundleFormat
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1000: Workspace close confirmation", .serialized)
  @MainActor
  struct UCT1000WorkspaceDocumentIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    @Test("UCT-1000.1: Cancel closing preserves unsaved changes")
    func cancelClosingPreservesUnsavedChanges() async throws {
      let fixture = try await WorkspaceCloseFixture()
      defer { fixture.cleanup() }
      let document = fixture.document
      let window = fixture.window
      let probe = WorkspaceCloseProbe()
      document.canClose(
        withDelegate: probe,
        shouldClose: #selector(WorkspaceCloseProbe.document(_:shouldClose:contextInfo:)),
        contextInfo: nil)
      try await clickCloseSheetButton("Cancel", in: window)
      for _ in 0..<100 where probe.result == nil { try await Task.sleep(for: .milliseconds(10)) }
      #expect(probe.result == false)
      #expect(document.isDocumentEdited)
      #expect(document.storeService.workspaceDefinition.displayName == "Pending")
      #expect(window.isVisible)
      #expect(UIComponentTestEnvironment.documentController.documents.contains { $0 === document })
    }

    @Test("UCT-1000.2: Discard closes without saving pending changes")
    func discardClosesWithoutSavingPendingChanges() async throws {
      let fixture = try await WorkspaceCloseFixture()
      defer { fixture.cleanup() }
      let document = fixture.document
      let window = fixture.window
      let probe = WorkspaceCloseProbe()
      document.canClose(
        withDelegate: probe,
        shouldClose: #selector(WorkspaceCloseProbe.document(_:shouldClose:contextInfo:)),
        contextInfo: nil)
      try await clickCloseSheetButton("Don’t Save", in: window)
      for _ in 0..<200 where probe.result == nil { try await Task.sleep(for: .milliseconds(10)) }
      #expect(probe.result == true)
      document.close()
      #expect(!UIComponentTestEnvironment.documentController.documents.contains { $0 === document })
      #expect(!window.isVisible)
      #expect(try WorkspaceBundleReaderV4(at: fixture.url).read().definition.displayName == "Close")
    }

    @Test("Valid unconfirmed edits prevent closing", arguments: [false, true])
    func validUnconfirmedEditsPreventClosing(inspector: Bool) async throws {
      let document = WorkspaceDocument()
      defer { document.close() }
      var pending = true
      var reportedErrors = 0
      document.editingState.inputValidationErrorHandler = { _ in reportedErrors += 1 }
      if inspector {
        document.editingState.registerInspectorEditValidator(
          id: UUID(), hasChanges: { pending }) {}
      } else {
        document.editingState.registerContentEditValidator(hasChanges: { pending }) {}
      }
      #expect(!document.isDocumentEdited)
      let probe = WorkspaceCloseProbe()
      document.canClose(
        withDelegate: probe,
        shouldClose: #selector(WorkspaceCloseProbe.document(_:shouldClose:contextInfo:)),
        contextInfo: nil)
      for _ in 0..<100 where probe.result == nil { try await Task.sleep(for: .milliseconds(10)) }
      #expect(probe.result == false)
      #expect(pending)
      #expect(reportedErrors == 1)
      pending = false
      probe.result = nil
      document.canClose(
        withDelegate: probe,
        shouldClose: #selector(WorkspaceCloseProbe.document(_:shouldClose:contextInfo:)),
        contextInfo: nil)
      for _ in 0..<100 where probe.result == nil { try await Task.sleep(for: .milliseconds(10)) }
      #expect(probe.result == true)
      #expect(reportedErrors == 1)
    }

    private func clickCloseSheetButton(_ title: String, in window: NSWindow) async throws {
      func find(_ view: NSView) -> NSButton? {
        if let button = view as? NSButton {
          let normalized = button.title.replacingOccurrences(of: "’", with: "'")
          let expected = title.replacingOccurrences(of: "’", with: "'")
          let japanese = ["Cancel": "キャンセル", "Don’t Save": "保存しない"][title]
          if normalized == expected || button.title == japanese { return button }
        }
        return view.subviews.lazy.compactMap { find($0) }.first
      }
      for _ in 0..<200 {
        if let content = window.attachedSheet?.contentView, let button = find(content) {
          button.performClick(nil)
          return
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      throw CocoaError(.userCancelled)
    }

  }
}
