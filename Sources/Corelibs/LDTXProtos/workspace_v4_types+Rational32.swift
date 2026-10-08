// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftProtobuf

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

public protocol Rational32Value: SwiftProtobuf.Message {
  var numerator: Int32 { get set }
  var denominator: UInt32 { get set }
}

extension Ldtx_Workspace_V4_Rational32: Rational32Value {}
extension Ldtx_Workspace_V4_Rational32DefaultOne: Rational32Value {}

extension Rational32Value {
  /// Copies the represented value, including the source type's fixed defaults.
  public init(value: some Rational32Value) {
    self.init()
    numerator = value.numerator
    denominator = value.denominator
  }

  public var float: Float { Float(double) }

  public var double: Double {
    return Double(numerator) / Double(denominator)
  }

  public var decimal: Decimal {
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
