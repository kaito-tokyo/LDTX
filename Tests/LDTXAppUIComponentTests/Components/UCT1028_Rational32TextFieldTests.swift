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

    @Test("Editing updates the draft and Enter submits its latest value without consuming Tab")
    func bindDraftAndSubmit() {
      var draft = "0"
      var submitted: [String] = []
      let field = Rational32TextField.IntegerField(
        title: "X numerator", text: Binding(get: { draft }, set: { draft = $0 }),
        onSubmit: { submitted.append(draft) })
      let coordinator = field.makeCoordinator()
      let control = NSTextField(string: "960")
      coordinator.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: control))
      #expect(draft == "960")
      #expect(submitted.isEmpty)
      let editor = NSTextView()
      editor.string = "1280"
      #expect(
        !coordinator.control(
          control, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
      #expect(
        coordinator.control(
          control, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
      #expect(draft == "1280")
      #expect(submitted == ["1280"])
    }
  }
}
