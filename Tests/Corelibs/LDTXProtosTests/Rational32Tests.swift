// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import Testing

@Suite("Rational32")
struct Rational32UnitTestSuite {
  @Test func decibelsUseFixedTenthsAndRejectInvalidValues() throws {
    for (input, numerator) in [(0.0, 0), (-11.899999999999999, -119), (1.26, 13)] {
      let value = try Rational32DecibelEncoding.encode(input)
      #expect(value.numerator == Int32(numerator))
      #expect(value.denominator == 10)
    }
    for input in [Double.nan, .infinity, -.infinity, Double(Int32.max), Double(Int32.min)] {
      #expect(throws: Rational32EncodingError.self) {
        try Rational32DecibelEncoding.encode(input)
      }
    }
    let zero = try Rational32DecibelEncoding.encode(Ldtx_Workspace_V4_Rational32().double)
    #expect(zero.numerator == 0 && zero.denominator == 10)
  }
  @Test func convertsValidValues() {
    let value = Ldtx_Workspace_V4_Rational32.with {
      $0.numerator = -1
      $0.denominator = 8
    }
    #expect(value.float == -0.125)
    #expect(value.double == -0.125)
  }

  @Test func usesStandardDivisionForZeroDenominator() {
    let value = Ldtx_Workspace_V4_Rational32.with {
      $0.numerator = 1
      $0.denominator = 0
    }
    #expect(value.float == .infinity)
    #expect(value.double == .infinity)
    let negative = Ldtx_Workspace_V4_Rational32.with {
      $0.numerator = -1
      $0.denominator = 0
    }
    #expect(negative.float == -.infinity)
    #expect(negative.double == -.infinity)
    #expect(Ldtx_Workspace_V4_Rational32().float == 0)
    #expect(Ldtx_Workspace_V4_Rational32().double == 0)
    #expect(Ldtx_Workspace_V4_Rational32().decimal == 0)
  }

  @Test func convertsZeroAndExtremeValues() {
    let zero = Ldtx_Workspace_V4_Rational32.with { $0.denominator = 1 }
    #expect(zero.float == 0)
    #expect(zero.double == 0)
    let extreme = Ldtx_Workspace_V4_Rational32.with {
      $0.numerator = Int32.min
      $0.denominator = UInt32.max
    }
    #expect(extreme.float == -0.5)
    #expect(extreme.double == Double(Int32.min) / Double(UInt32.max))
  }

  @Test func invalidStoredDenominator() {
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.scaleY = .with { $0.set(num: 1, den: 0) }
    #expect(throws: WorkspaceV4IntegrityError.invalidRational) {
      try WorkspaceV4IntegrityValidator.validateTransform(transform)
    }
  }

  @Test func castsDoubleToFloat() {
    let value = Ldtx_Workspace_V4_Rational32.with {
      $0.numerator = Int32.max
      $0.denominator = UInt32.max
    }
    #expect(value.float == Float(value.double))
  }

  @Test func convertsPowersOfTwoAcrossIntegerBitWidths() {
    for numeratorExponent in 0...30 {
      for denominatorExponent in 0...31 {
        let value = Ldtx_Workspace_V4_Rational32.with {
          $0.numerator = 1 << numeratorExponent
          $0.denominator = 1 << denominatorExponent
        }
        #expect(
          value.double
            == Double(
              sign: .plus, exponent: numeratorExponent - denominatorExponent, significand: 1))
      }
    }
  }

  @Test func validatesWithoutRounding() {
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.translationX = .with {
      $0.numerator = Int32.max
      $0.denominator = UInt32(Int32.max - 1)
    }
    #expect(transform.translationX.double > 1)
    #expect(throws: WorkspaceV4IntegrityError.invalidBasicTransform) {
      try WorkspaceV4IntegrityValidator.validateTransform(transform)
    }
  }
  @Test func decimalRoundTripAndEncodingLimits() throws {
    var value = Ldtx_Workspace_V4_Rational32()
    for text in ["1.25", "-1.2", "0", "1000", "0.000000001", "-2147483648"] {
      let decimal = try #require(Decimal(string: text))
      try value.set(decimal: decimal)
      #expect(value.decimal == decimal)
      #expect(value.denominator > 0)
    }
    try value.set(decimal: Decimal(string: "1.25")!)
    #expect(value.numerator == 125)
    #expect(value.denominator == 100)
    let original = value
    for text in ["2147483648", "0.0000000001", "123456789012345678901234567890"] {
      #expect(throws: Rational32EncodingError.self) {
        try value.set(decimal: Decimal(string: text)!)
      }
      #expect(value == original)
    }
    value.set(num: 0, den: 0)
    #expect(value.numerator == 0 && value.denominator == 0)
    #expect(value.decimal.isNaN)
    #expect(value.double.isNaN)
    #expect(try Ldtx_Workspace_V4_Rational32(serializedBytes: value.serializedData()) == value)
  }

}
