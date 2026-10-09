// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

class NullableIntegerFormatter<Value: FixedWidthInteger>: NumberFormatter, @unchecked Sendable {
  override init() {
    super.init()
    numberStyle = .decimal
    allowsFloats = false
    usesGroupingSeparator = false
    isLenient = false
    minimumFractionDigits = 0
    maximumFractionDigits = 0
    minimum = NSDecimalNumber(string: String(Value.min))
    maximum = NSDecimalNumber(string: String(Value.max))
  }

  override func string(for obj: Any?) -> String? {
    guard let obj else { return "" }
    return super.string(for: obj)
  }

  override func getObjectValue(
    _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
    for string: String,
    errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
  ) -> Bool {
    if string.isEmpty {
      obj?.pointee = nil
      return true
    }
    return super.getObjectValue(obj, for: string, errorDescription: error)
  }

  required init?(coder: NSCoder) {
    return nil
  }
}
