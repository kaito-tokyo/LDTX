// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension NanopbMessage {
  public static func fromJSONObject(_ value: Any) throws -> Self {
    var result = Self()
    try result.merge(jsonObject: NanopbJSON.object(value))
    return result
  }
}

// Only the ProtoJSON scalar conversions used by the checked-in schemas.
enum NanopbJSON {
  static func object(_ value: Any) throws -> [String: Any] {
    guard let result = value as? [String: Any] else { throw NanopbError.invalidJSON }
    return result
  }

  static func array(_ value: Any) throws -> [Any] {
    guard let result = value as? [Any] else { throw NanopbError.invalidJSON }
    return result
  }

  static func string(_ value: Any) throws -> String {
    guard let result = value as? String else { throw NanopbError.invalidJSON }
    return result
  }

  static func bool(_ value: Any) throws -> Bool {
    guard let result = value as? NSNumber, String(cString: result.objCType) == "c" else {
      throw NanopbError.invalidJSON
    }
    return result.boolValue
  }

  static func boolKey(_ value: String) throws -> Bool {
    guard value == "true" || value == "false" else { throw NanopbError.invalidJSON }
    return value == "true"
  }

  static func data(_ value: Any) throws -> Data {
    var encoded = try string(value).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while encoded.count % 4 != 0 { encoded += "=" }
    guard let result = Data(base64Encoded: encoded) else { throw NanopbError.invalidJSON }
    return result
  }

  static func integer<T: FixedWidthInteger>(_ value: Any, as: T.Type) throws -> T {
    let text: String
    if let value = value as? String {
      text = value
    } else if let value = value as? NSNumber, String(cString: value.objCType) != "c" {
      text = value.stringValue
    } else {
      throw NanopbError.invalidJSON
    }
    if let result = T(text) { return result }
    // ProtoJSON also permits integral decimal/exponent forms. Decimal avoids
    // silently rounding 64-bit values through Double.
    guard let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
      let result = T(NSDecimalNumber(decimal: decimal).stringValue)
    else { throw NanopbError.invalidJSON }
    return result
  }

  static func floating<T: BinaryFloatingPoint & LosslessStringConvertible>(
    _ value: Any, as: T.Type
  ) throws -> T {
    if let text = value as? String {
      switch text {
      case "NaN": return .nan
      case "Infinity": return .infinity
      case "-Infinity": return -.infinity
      default:
        guard let result = T(text) else { throw NanopbError.invalidJSON }
        return result
      }
    }
    guard let number = value as? NSNumber, String(cString: number.objCType) != "c" else {
      throw NanopbError.invalidJSON
    }
    return T(number.doubleValue)
  }

  static func floatingValue<T: BinaryFloatingPoint>(_ value: T) -> Any {
    if value.isNaN { return "NaN" }
    if value == .infinity { return "Infinity" }
    if value == -.infinity { return "-Infinity" }
    return Double(value)
  }
}
