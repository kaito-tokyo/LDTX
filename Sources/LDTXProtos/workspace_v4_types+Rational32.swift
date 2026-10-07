// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum Rational32EncodingError: Error, LocalizedError {
  case unrepresentableDecimal

  public var errorDescription: String? {
    "The decimal cannot be represented by a 32-bit Rational."
  }
}

extension Ldtx_Workspace_V4_Rational32 {
  public var float: Float { Float(double) }

  public var double: Double {
    if numerator == 0 && denominator == 0 { return 0 }
    return Double(numerator) / Double(denominator)
  }

  public var decimal: Decimal {
    if numerator == 0 && denominator == 0 { return 0 }
    return Decimal(numerator) / Decimal(denominator)
  }

  public mutating func set(num: Int32, den: UInt32) {
    numerator = num
    denominator = den
  }

  public mutating func set(decimal: Decimal) throws {
    guard decimal.isFinite, (-9...9).contains(decimal.exponent),
      let coefficient = Int128(NSDecimalNumber(decimal: decimal.significand).stringValue),
      coefficient <= Int128(Int32.max) + 1
    else { throw Rational32EncodingError.unrepresentableDecimal }
    var numerator = decimal.sign == .minus ? -coefficient : coefficient
    var denominator: UInt32 = 1
    if decimal.exponent < 0 {
      for _ in 0..<(-decimal.exponent) { denominator *= 10 }
    } else {
      for _ in 0..<decimal.exponent { numerator *= 10 }
    }
    guard let numerator = Int32(exactly: numerator) else {
      throw Rational32EncodingError.unrepresentableDecimal
    }
    set(num: numerator, den: denominator)
  }
}
