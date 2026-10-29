// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite.Shard1 {
  @Suite("UCT-1028: Rational32TextField", .serialized)
  @MainActor
  struct UCT1028Rational32TextFieldUnitTestSuite {
    struct DigitInput: Sendable, Codable {
      let input: String
      let accepted: Bool
    }

    @Test(
      "LUB-1048: Digit input determines draft and final acceptance",
      arguments: [
        DigitInput(input: "", accepted: true),
        DigitInput(input: "0", accepted: true),
        DigitInput(input: "1920", accepted: true),
        DigitInput(input: "0001", accepted: true),
        DigitInput(input: "-1", accepted: false),
        DigitInput(input: "+1", accepted: false),
        DigitInput(input: "1.5", accepted: false),
        DigitInput(input: "1/2", accepted: false),
        DigitInput(input: "１２", accepted: false),
        DigitInput(input: "12px", accepted: false),
        DigitInput(input: "1 2", accepted: false),
        DigitInput(input: "12\n", accepted: false),
      ])
    func digitInput(_ data: DigitInput) {
      let formatter = Rational32TextField.DigitsFormatter()
      #expect(
        formatter.isPartialStringValid(data.input, newEditingString: nil, errorDescription: nil)
          == data.accepted)
      var object: AnyObject?
      #expect(
        formatter.getObjectValue(&object, for: data.input, errorDescription: nil) == data.accepted)
      if data.accepted { #expect(object as? String == data.input) }
    }

    @Test("LUB-1048: SwiftUI editing updates drafts and submits the current value")
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
