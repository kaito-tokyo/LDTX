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

    @Test("Int32 and UInt32 permit intermediate text but reject invalid characters and overflow")
    func validateRanges() {
      let signed = IntegerField<Int32>.IntegerFormatter()
      let unsigned = IntegerField<UInt32>.IntegerFormatter()
      for text in ["", "0", "2147483647", "0001"] {
        #expect(signed.isPartialStringValid(text, newEditingString: nil, errorDescription: nil))
        #expect(unsigned.isPartialStringValid(text, newEditingString: nil, errorDescription: nil))
      }
      for text in ["-", "-2147483648", "-1"] {
        #expect(signed.isPartialStringValid(text, newEditingString: nil, errorDescription: nil))
        #expect(!unsigned.isPartialStringValid(text, newEditingString: nil, errorDescription: nil))
      }
      #expect(!signed.getObjectValue(nil, for: "", errorDescription: nil))
      #expect(!signed.getObjectValue(nil, for: "-", errorDescription: nil))
      #expect(
        unsigned.isPartialStringValid("4294967295", newEditingString: nil, errorDescription: nil))
      for text in ["2147483648", "-2147483649"] {
        #expect(!signed.isPartialStringValid(text, newEditingString: nil, errorDescription: nil))
      }
      #expect(
        !unsigned.isPartialStringValid("4294967296", newEditingString: nil, errorDescription: nil))
      for text in ["1.5", "1/2", "+1", "１２", "1 2", "12px", "1\n"] {
        #expect(!signed.getObjectValue(nil, for: text, errorDescription: nil))
        #expect(!unsigned.getObjectValue(nil, for: text, errorDescription: nil))
      }
    }

    @Test("Formatter round-trips full Int32 and UInt32 values without loss")
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

    @Test("Hosted IntegerField commits through TextField and invokes SwiftUI onSubmit")
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
