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

public enum Rational32DecibelEncoding {
  public static func encode(_ decibels: Double) throws -> Ldtx_Workspace_V4_Rational32 {
    guard decibels.isFinite,
      let numerator = Int32(exactly: (decibels * 10).rounded())
    else { throw Rational32EncodingError.unrepresentableDecimal }
    var result = Ldtx_Workspace_V4_Rational32()
    result.set(num: numerator, den: 10)
    return result
  }
}

public protocol Rational32Value: NanopbMessage {
  var num: Int32? { get set }
  var den: UInt32? { get set }
}

extension Ldtx_Workspace_V4_Rational32: Rational32Value {}
extension Ldtx_Workspace_V4_Rational32DefaultOne: Rational32Value {}

extension Rational32Value {
  /// Copies the stored value without changing presence.
  public init(value: some Rational32Value) {
    self.init()
    num = value.num
    den = value.den
  }

  public func double(defaultNumerator: Int32, defaultDenominator: UInt32) -> Double {
    Double(num ?? defaultNumerator) / Double(den ?? defaultDenominator)
  }

  public func float(defaultNumerator: Int32, defaultDenominator: UInt32) -> Float {
    Float(double(defaultNumerator: defaultNumerator, defaultDenominator: defaultDenominator))
  }

  public func decimal(defaultNumerator: Int32, defaultDenominator: UInt32) -> Decimal {
    Decimal(num ?? defaultNumerator) / Decimal(den ?? defaultDenominator)
  }

  public mutating func set(num: Int32, den: UInt32) {
    self.num = num
    self.den = den
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
