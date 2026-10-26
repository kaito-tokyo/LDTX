// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import LDTXMessages
import Testing

#if os(Linux)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite("Rational32")
struct Rational32UnitTestSuite {
  @Test("LUB-1000: Optional fields preserve presence") func optionalFieldsPreservePresence() throws
  {
    try checkOptionalFields(Ldtx_Workspace_V4_Rational32(), defaultNum: 0)
    try checkOptionalFields(Ldtx_Workspace_V4_Rational32DefaultOne(), defaultNum: 1)
  }

  private func checkOptionalFields<Value: Rational32Value>(
    _ initial: Value, defaultNum: Int32
  ) throws {
    var value = initial
    #expect(value.num == nil && value.den == nil)
    value.num = 0
    value.den = 1
    let restored = try Value(serializedBytes: value.serializedData())
    #expect(restored.num == 0 && restored.den == 1)
    value.num = nil
    #expect((value.num == nil) && value.den == 1)
    value.den = nil
    #expect((value.den == nil) && value.num == nil && value.den == nil)
    #expect(try value.serializedData().isEmpty)
  }

  @Test("LUB-1000: Decibels use fixed tenths and reject invalid values")
  func decibelsUseFixedTenthsAndRejectInvalidValues() throws {
    for (input, numerator) in [(0.0, 0), (-11.899999999999999, -119), (1.26, 13)] {
      let value = try Rational32DecibelEncoding.encode(input)
      #expect(value.num == Int32(numerator))
      #expect(value.den == 10)
    }
    for input in [Double.nan, .infinity, -.infinity, Double(Int32.max), Double(Int32.min)] {
      #expect(throws: Rational32EncodingError.self) {
        try Rational32DecibelEncoding.encode(input)
      }
    }
    let zero = try Rational32DecibelEncoding.encode(
      Ldtx_Workspace_V4_Rational32().double)
    #expect(zero.num == 0 && zero.den == 10)
  }
  @Test("LUB-1000: Converts valid values") func convertsValidValues() {
    let value = Ldtx_Workspace_V4_Rational32.with {
      $0.num = -1
      $0.den = 8
    }
    #expect(value.float == -0.125)
    #expect(value.double == -0.125)
  }

  @Test("LUB-1000: Uses standard division for zero denominator")
  func usesStandardDivisionForZeroDenominator() {
    let value = Ldtx_Workspace_V4_Rational32.with {
      $0.num = 1
      $0.den = 0
    }
    #expect(value.float == .infinity)
    #expect(value.double == .infinity)
    let negative = Ldtx_Workspace_V4_Rational32.with {
      $0.num = -1
      $0.den = 0
    }
    #expect(negative.float == -.infinity)
    #expect(negative.double == -.infinity)
    #expect(Ldtx_Workspace_V4_Rational32().float == 0)
    #expect(Ldtx_Workspace_V4_Rational32().double == 0)
    #expect(Ldtx_Workspace_V4_Rational32().decimal == 0)
  }

  @Test("LUB-1000: Converts zero and extreme values") func convertsZeroAndExtremeValues() {
    let zero = Ldtx_Workspace_V4_Rational32.with { $0.den = 1 }
    #expect(zero.float == 0)
    #expect(zero.double == 0)
    let extreme = Ldtx_Workspace_V4_Rational32.with {
      $0.num = Int32.min
      $0.den = UInt32.max
    }
    #expect(extreme.float == -0.5)
    #expect(
      extreme.double == Double(Int32.min)
        / Double(UInt32.max))
  }

  @Test("LUB-1000: Invalid stored denominator") func invalidStoredDenominator() {
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.scaleY = .with { $0.set(num: 1, den: 0) }
    #expect(
      performing: {
        try WorkspaceBundleValidatorV4.validateTransform(transform)
      },
      throws: {
        ($0 as? WorkspaceV4ValidationError)?.diagnostics.contains { $0.error == .invalidRational }
          == true
      })
  }

  @Test("LUB-1000: Validates without rounding") func validatesWithoutRounding() {
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.translationX = .with {
      $0.num = Int32.max
      $0.den = UInt32(Int32.max - 1)
    }
    #expect((transform.translationX?.double ?? 0) > 1)
    #expect(
      performing: {
        try WorkspaceBundleValidatorV4.validateTransform(transform)
      },
      throws: {
        ($0 as? WorkspaceV4ValidationError)?.diagnostics.contains {
          $0.error == .invalidBasicTransform
        } == true
      })
  }
  @Test("LUB-1000: Decimal round trip and encoding limits") func decimalRoundTripAndEncodingLimits()
    throws
  {
    var value = Ldtx_Workspace_V4_Rational32()
    for text in ["1.25", "-1.2", "0", "1000", "0.000000001", "-2147483648"] {
      let decimal = try #require(Decimal(string: text))
      try value.set(decimal: decimal)
      #expect(value.decimal == decimal)
      #expect((value.den ?? 0) > 0)
    }
    try value.set(decimal: Decimal(string: "1.25")!)
    #expect(value.num == 125)
    #expect(value.den == 100)
    let original = value
    for text in ["2147483648", "0.0000000001", "123456789012345678901234567890"] {
      #expect(throws: Rational32EncodingError.self) {
        try value.set(decimal: Decimal(string: text)!)
      }
      #expect(value == original)
    }
    value.set(num: 0, den: 0)
    #expect(value.num == 0 && value.den == 0)
    #expect(value.decimal.isNaN)
    #expect(value.double.isNaN)
    #expect(try Ldtx_Workspace_V4_Rational32(serializedBytes: value.serializedData()) == value)
  }

}
