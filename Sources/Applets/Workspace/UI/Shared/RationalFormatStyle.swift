// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import SwiftUI

enum RationalInputError: Error, LocalizedError {
  case invalidNumber, zeroDenominator, overflow
  var errorDescription: String? {
    switch self {
    case .invalidNumber: "Enter a decimal number or a fraction."
    case .zeroDenominator: "A Rational denominator must be greater than zero."
    case .overflow: "The number cannot be represented by a 32-bit Rational."
    }
  }
}

struct RationalFormatStyle: ParseableFormatStyle {
  var multiplier: UInt64 = 1
  var parseStrategy: RationalParseStrategy { RationalParseStrategy(divisor: multiplier) }
  func format(_ value: Ldtx_Workspace_V4_Rational32) -> String {
    guard value.denominator > 0 else { return "" }
    var magnitude = Int128(value.numerator).magnitude * UInt128(multiplier)
    var denominator = UInt128(value.denominator)
    var a = magnitude
    var b = denominator
    while b != 0 { (a, b) = (b, a % b) }
    magnitude /= a
    denominator /= a
    var d = denominator
    while d % 2 == 0 { d /= 2 }
    while d % 5 == 0 { d /= 5 }
    guard d == 1 else { return "\(value.numerator < 0 ? "-" : "")\(magnitude)/\(denominator)" }
    let divisor = UInt128(denominator)
    var output = (value.numerator < 0 ? "-" : "") + String(magnitude / divisor)
    var remainder = magnitude % divisor
    if remainder != 0 { output += "." }
    while remainder != 0 {
      remainder *= 10
      output += String(remainder / divisor)
      remainder %= divisor
    }
    return output
  }

}

struct RationalParseStrategy: ParseStrategy {
  var divisor: UInt64 = 1
  func parse(_ text: String) throws -> Ldtx_Workspace_V4_Rational32 {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.contains("/") {
      let parts = text.split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 2, let n = Int64(parts[0]), let d = UInt64(parts[1]) else {
        throw RationalInputError.invalidNumber
      }
      return try Self.reduced(Int128(n), UInt128(d) * UInt128(divisor))
    }
    let exponentParts = text.lowercased().split(separator: "e", omittingEmptySubsequences: false)
    guard (1...2).contains(exponentParts.count) else { throw RationalInputError.invalidNumber }
    let exponent: Int
    if exponentParts.count == 2 {
      guard let parsed = Int(exponentParts[1]), (-38...38).contains(parsed) else {
        throw RationalInputError.overflow
      }
      exponent = parsed
    } else {
      exponent = 0
    }
    var mantissa = String(exponentParts[0])
    let negative = mantissa.first == "-"
    if mantissa.first == "-" || mantissa.first == "+" { mantissa.removeFirst() }
    let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
    let digits = parts.joined()
    guard (1...2).contains(parts.count), !digits.isEmpty,
      digits.utf8.allSatisfy({ (48...57).contains($0) }),
      let magnitude = Int128(digits)
    else { throw RationalInputError.invalidNumber }
    var n = negative ? -magnitude : magnitude
    if n == 0 {
      return .with { $0.denominator = 1 }
    }
    let places = (parts.count == 2 ? parts[1].count : 0) - exponent
    guard (-38...38).contains(places) else { throw RationalInputError.overflow }
    var d: UInt128 = 1
    if places >= 0 {
      for _ in 0..<places { d *= 10 }
    } else {
      for _ in 0..<(-places) {
        let product = n.multipliedReportingOverflow(by: 10)
        guard !product.overflow else { throw RationalInputError.overflow }
        n = product.partialValue
      }
    }
    let scaled = d.multipliedReportingOverflow(by: UInt128(divisor))
    guard !scaled.overflow else { throw RationalInputError.overflow }
    return try Self.reduced(n, scaled.partialValue)
  }

  private static func reduced(_ numerator: Int128, _ denominator: UInt128) throws
    -> Ldtx_Workspace_V4_Rational32
  {
    guard denominator > 0 else { throw RationalInputError.zeroDenominator }
    if numerator == 0 { return .with { $0.denominator = 1 } }
    var a = numerator.magnitude
    var b = denominator
    while b != 0 { (a, b) = (b, a % b) }
    guard let n = Int32(exactly: numerator / Int128(a)),
      let d = UInt32(exactly: denominator / a)
    else { throw RationalInputError.overflow }
    var result = Ldtx_Workspace_V4_Rational32()
    result.numerator = n
    result.denominator = d
    return result
  }
}

extension Binding where Value == Ldtx_Workspace_V4_Rational32 {
  var double: Binding<Double> {
    Binding<Double>(
      get: { wrappedValue.double },
      set: {
        if let value = try? RationalParseStrategy().parse(String($0)) { wrappedValue = value }
      })
  }
}
