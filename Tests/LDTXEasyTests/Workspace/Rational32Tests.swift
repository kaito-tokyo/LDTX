// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import Testing

@Suite("Rational32")
struct Rational32UnitTestSuite {
  @Test func convertsValidValues() {
    let value = Ldtx_Workspace_V4_Rational32.with {
      $0.numerator = -1
      $0.denominator = 8
    }
    #expect(value.float == -0.125)
    #expect(value.double == -0.125)
  }

  @Test func usesStandardDivisionForZeroDenominator() {
    let value = Ldtx_Workspace_V4_Rational32.with { $0.numerator = 1 }
    #expect(value.float == .infinity)
    #expect(value.double == .infinity)
    let negative = Ldtx_Workspace_V4_Rational32.with { $0.numerator = -1 }
    #expect(negative.float == -.infinity)
    #expect(negative.double == -.infinity)
    #expect(Ldtx_Workspace_V4_Rational32().float.isNaN)
    #expect(Ldtx_Workspace_V4_Rational32().double.isNaN)
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
    transform.scaleYRational = .init()
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
    transform.translationXRational = .with {
      $0.numerator = Int32.max
      $0.denominator = UInt32(Int32.max - 1)
    }
    #expect(transform.translationXRational.double > 1)
    #expect(throws: WorkspaceV4IntegrityError.invalidBasicTransform) {
      try WorkspaceV4IntegrityValidator.validateTransform(transform)
    }
  }
}
