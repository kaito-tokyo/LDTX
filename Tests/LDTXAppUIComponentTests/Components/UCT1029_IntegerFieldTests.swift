// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1029: Typed integer input", .serialized)
  @MainActor
  struct UCT1029IntegerFieldUnitTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    struct IntegerInput: Sendable, Codable {
      let input: String
      let signedDraft: Bool
      let unsignedDraft: Bool
      let signedValue: Bool
      let unsignedValue: Bool
    }

    @Test(
      "LUB-1048: Integer input determines signed and unsigned draft and value acceptance",
      arguments: [
        IntegerInput(
          input: "", signedDraft: true, unsignedDraft: true, signedValue: false,
          unsignedValue: false),
        IntegerInput(
          input: "0", signedDraft: true, unsignedDraft: true, signedValue: true, unsignedValue: true
        ),
        IntegerInput(
          input: "0001", signedDraft: true, unsignedDraft: true, signedValue: true,
          unsignedValue: true),
        IntegerInput(
          input: "-", signedDraft: true, unsignedDraft: false, signedValue: false,
          unsignedValue: false),
        IntegerInput(
          input: "-1", signedDraft: true, unsignedDraft: false, signedValue: true,
          unsignedValue: false),
        IntegerInput(
          input: "2147483647", signedDraft: true, unsignedDraft: true, signedValue: true,
          unsignedValue: true),
        IntegerInput(
          input: "2147483648", signedDraft: false, unsignedDraft: true, signedValue: false,
          unsignedValue: true),
        IntegerInput(
          input: "-2147483648", signedDraft: true, unsignedDraft: false, signedValue: true,
          unsignedValue: false),
        IntegerInput(
          input: "-2147483649", signedDraft: false, unsignedDraft: false, signedValue: false,
          unsignedValue: false),
        IntegerInput(
          input: "4294967295", signedDraft: false, unsignedDraft: true, signedValue: false,
          unsignedValue: true),
        IntegerInput(
          input: "4294967296", signedDraft: false, unsignedDraft: false, signedValue: false,
          unsignedValue: false),
        IntegerInput(
          input: "1.5", signedDraft: false, unsignedDraft: false, signedValue: false,
          unsignedValue: false),
        IntegerInput(
          input: "1/2", signedDraft: false, unsignedDraft: false, signedValue: false,
          unsignedValue: false),
        IntegerInput(
          input: "+1", signedDraft: false, unsignedDraft: false, signedValue: false,
          unsignedValue: false),
        IntegerInput(
          input: "１２", signedDraft: false, unsignedDraft: false, signedValue: false,
          unsignedValue: false),
        IntegerInput(
          input: "1 2", signedDraft: false, unsignedDraft: false, signedValue: false,
          unsignedValue: false),
        IntegerInput(
          input: "12px", signedDraft: false, unsignedDraft: false, signedValue: false,
          unsignedValue: false),
        IntegerInput(
          input: "1\n", signedDraft: false, unsignedDraft: false, signedValue: false,
          unsignedValue: false),
      ])
    func integerInput(_ data: IntegerInput) {
      let signed = IntegerField<Int32>.IntegerFormatter()
      let unsigned = IntegerField<UInt32>.IntegerFormatter()
      #expect(
        signed.isPartialStringValid(data.input, newEditingString: nil, errorDescription: nil)
          == data.signedDraft)
      #expect(
        unsigned.isPartialStringValid(data.input, newEditingString: nil, errorDescription: nil)
          == data.unsignedDraft)
      #expect(
        signed.getObjectValue(nil, for: data.input, errorDescription: nil) == data.signedValue)
      #expect(
        unsigned.getObjectValue(nil, for: data.input, errorDescription: nil) == data.unsignedValue)
    }

    @Test("LUB-1048: Formatter round-trips full Int32 and UInt32 values without loss")
    func typedObjects() {
      let signed = IntegerField<Int32>.IntegerFormatter()
      let unsigned = IntegerField<UInt32>.IntegerFormatter()
      for value in [Int32.min, -1, 0, Int32.max] {
        var object: AnyObject?
        #expect(signed.getObjectValue(&object, for: String(value), errorDescription: nil))
        #expect(object as? Int32 == value)
        #expect(signed.string(for: object) == String(value))
      }
      for value in [UInt32.min, UInt32.max] {
        var object: AnyObject?
        #expect(unsigned.getObjectValue(&object, for: String(value), errorDescription: nil))
        #expect(object as? UInt32 == value)
        #expect(unsigned.string(for: object) == String(value))
      }
    }

    @Test("LUB-1048: Hosted IntegerField commits through TextField and invokes SwiftUI onSubmit")
    func nativeSubmit() async throws {
      var value: Int32 = 42
      var submitted: [Int32] = []
      let view = NSHostingView(
        rootView:
          IntegerField("Signed integer", value: Binding(get: { value }, set: { value = $0 }))
          .onSubmit { submitted.append(value) }
          .frame(width: 150)
      )
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .titled,
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      window.contentView = view
      view.layoutSubtreeIfNeeded()
      func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
      }
      let control = try #require(fields(view).first(where: { $0.isEditable }))
      #expect(window.makeFirstResponder(control))
      let editor = try #require(control.currentEditor() as? NSTextView)
      editor.insertText(
        "-2147483648", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
      editor.insertNewline(nil)
      try await Task.sleep(for: .milliseconds(100))
      #expect(value == Int32.min)
      #expect(submitted == [Int32.min])
    }
  }
}
