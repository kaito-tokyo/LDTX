// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// Edits a Rational numerator and denominator while the owner retains the draft.
struct Rational32TextField: View {
  @Binding var numerator: String
  @Binding var denominator: String
  var accessibilityLabel = "Rational"
  var onSubmit: () -> Void = {}

  var body: some View {
    HStack {
      IntegerField(title: "\(accessibilityLabel) numerator", text: $numerator, onSubmit: onSubmit)
        .frame(width: 90)
      Text("/")
      IntegerField(
        title: "\(accessibilityLabel) denominator", text: $denominator, onSubmit: onSubmit
      )
      .frame(width: 90)
    }
  }

  struct IntegerField: NSViewRepresentable {
    let title: String
    @Binding var text: String
    var onSubmit: () -> Void
    @Environment(\.isEnabled) var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(field: self) }

    func makeNSView(context: Context) -> NSTextField {
      let field = NSTextField(string: text)
      field.alignment = .right
      field.formatter = DigitsFormatter()
      field.delegate = context.coordinator
      field.setAccessibilityLabel(title)
      return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
      context.coordinator.field = self
      field.isEnabled = isEnabled
      field.setAccessibilityLabel(title)
      if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
      var field: IntegerField
      init(field: IntegerField) { self.field = field }

      func controlTextDidChange(_ notification: Notification) {
        guard let control = notification.object as? NSTextField else { return }
        field.text = control.stringValue
      }

      func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector)
        -> Bool
      {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        field.text = textView.string
        field.onSubmit()
        return true
      }
    }
  }

  final class DigitsFormatter: Formatter {
    static func accepts(_ text: String) -> Bool {
      text.utf8.allSatisfy { (48...57).contains($0) }
    }

    override func string(for obj: Any?) -> String? { obj as? String }

    override func getObjectValue(
      _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
      errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
      guard Self.accepts(string) else { return false }
      obj?.pointee = string as NSString
      return true
    }

    override func isPartialStringValid(
      _ partialString: String,
      newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?,
      errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
      Self.accepts(partialString)
    }
  }
}

#if DEBUG
  #Preview("Default") {
    @Previewable @State var numerator = "960"
    @Previewable @State var denominator = "1920"
    @Previewable @State var submittedValue = "Not submitted"

    Form {
      LabeledContent("X") {
        Rational32TextField(
          numerator: $numerator, denominator: $denominator, accessibilityLabel: "X"
        ) {
          submittedValue = "\(numerator) / \(denominator)"
        }
      }
      LabeledContent("Submitted", value: submittedValue)
    }
    .formStyle(.grouped)
    .frame(width: 420, height: 180)
  }

  #Preview("Disabled") {
    @Previewable @State var numerator = "1080"
    @Previewable @State var denominator = "1080"

    Form {
      LabeledContent("Height") {
        Rational32TextField(
          numerator: $numerator, denominator: $denominator, accessibilityLabel: "Height"
        )
        .disabled(true)
      }
    }
    .formStyle(.grouped)
    .frame(width: 420, height: 140)
  }
#endif
