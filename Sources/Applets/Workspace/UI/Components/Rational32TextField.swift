// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

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

  struct IntegerField: View {
    let title: String
    @Binding var text: String
    var onSubmit: () -> Void

    var body: some View {
      TextField(
        title,
        text: Binding(
          get: { text },
          set: { if DigitsFormatter.accepts($0) { text = $0 } })
      )
      .multilineTextAlignment(.trailing)
      .textFieldStyle(.roundedBorder)
      .accessibilityLabel(title)
      .onSubmit(onSubmit)
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
