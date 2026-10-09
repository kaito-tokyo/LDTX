// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftUI

struct IntegerField<Value: FixedWidthInteger>: View {
  let title: LocalizedStringResource
  @Binding var value: Value

  init(_ title: LocalizedStringResource, value: Binding<Value>) {
    self.title = title
    self._value = value
  }

  var body: some View {
    TextField(title, value: $value, formatter: IntegerFormatter())
      .labelsHidden()
      .multilineTextAlignment(.trailing)
  }

  final class IntegerFormatter: Formatter {
    static func accepts(_ text: String) -> Bool {
      text.isEmpty || (Value.isSigned && text == "-")
        || (!text.hasPrefix("+") && Value(text) != nil)
    }

    override func string(for obj: Any?) -> String? {
      guard let value = obj as? Value else { return nil }
      return String(value)
    }

    override func getObjectValue(
      _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
      errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
      guard Self.accepts(string), let value = Value(string) else { return false }
      obj?.pointee = value as AnyObject
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
  #Preview("Int32 and UInt32") {
    @Previewable @State var signedValue: Int32 = -960
    @Previewable @State var unsignedValue: UInt32 = 1920
    @Previewable @State var submittedValue = "Not submitted"

    Form {
      LabeledContent("Int32") {
        IntegerField("Signed integer", value: $signedValue)
          .onSubmit {
            submittedValue = String(signedValue)
          }
          .frame(width: 120)
      }
      LabeledContent("UInt32") {
        IntegerField("Unsigned integer", value: $unsignedValue)
          .onSubmit {
            submittedValue = String(unsignedValue)
          }
          .frame(width: 120)
      }
      LabeledContent("Submitted", value: submittedValue)
    }
    .formStyle(.grouped)
    .frame(width: 420, height: 230)
  }

  #Preview("Disabled") {
    @Previewable @State var value: UInt32 = 1080
    IntegerField("Disabled integer", value: $value)
      .disabled(true)
      .frame(width: 120)
      .padding()
  }
#endif
