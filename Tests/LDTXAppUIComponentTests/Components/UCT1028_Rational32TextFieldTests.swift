// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1028: Rational32TextField", .serialized)
  @MainActor
  struct UCT1028Rational32TextFieldUnitTestSuite {
    @Test(
      "Partial and final validation accept digits and empty drafts, rejecting invalid pasted text")
    func validateEditingText() {
      let formatter = Rational32TextField.DigitsFormatter()
      for text in ["", "0", "1920", "0001"] {
        #expect(formatter.isPartialStringValid(text, newEditingString: nil, errorDescription: nil))
        var object: AnyObject?
        #expect(formatter.getObjectValue(&object, for: text, errorDescription: nil))
        #expect(object as? String == text)
      }
      for text in ["-1", "+1", "1.5", "1/2", "１２", "12px", "1 2", "12\n"] {
        #expect(!formatter.isPartialStringValid(text, newEditingString: nil, errorDescription: nil))
        #expect(!formatter.getObjectValue(nil, for: text, errorDescription: nil))
      }
    }

    @Test("SwiftUI editing updates drafts and submits the current value")
    func bindDraftAndSubmit() async throws {
      var draft = "0"
      var submitted: [String] = []
      let field = Rational32TextField.IntegerField(
        title: "X numerator", text: Binding(get: { draft }, set: { draft = $0 }),
        onSubmit: { submitted.append(draft) })
      let window = hostWorkspaceView(field)
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      let control = try #require(
        workspaceDescendants(window.contentView!)
          .compactMap { $0 as? NSTextField }.first { $0.isEditable })
      try editWorkspaceField(control, text: "960", window: window)
      await settleWorkspaceToolbar(window)
      #expect(draft == "960")
      #expect(submitted.isEmpty)
      let editor = try #require(control.currentEditor() as? NSTextView)
      editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
      await settleWorkspaceToolbar(window)
      #expect(submitted == ["960"])
    }
  }
}
