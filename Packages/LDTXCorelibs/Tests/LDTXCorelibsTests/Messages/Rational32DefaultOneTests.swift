// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import LDTXMessages
import Testing

#if os(Linux)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite struct Rational32DefaultOneUnitTestSuite {
  @Test("LUB-1000: Message types own fixed numeric defaults") func messageTypesOwnDefaults() throws
  {
    let zero = Ldtx_Workspace_V4_Rational32()
    let one = Ldtx_Workspace_V4_Rational32DefaultOne()
    #expect(zero.double == 0)
    #expect(one.double == 1)
    #expect(one.decimal == 1)
    #expect((one.num == nil) && (one.den == nil))
    #expect(try one.serializedData().isEmpty)
    let transform = Ldtx_Workspace_V4_BasicTransform()
    #expect(transform.translationX == nil)
    #expect((transform.scaleX == nil) && (transform.scaleY == nil))
    let region = Ldtx_Workspace_V4_VisionRegionOfInterest()
    #expect(region.x == nil && region.y == nil)
    #expect(region.width == nil && region.height == nil)
    try WorkspaceBundleValidatorV4.validateRegionOfInterest(region)
  }

  @Test("LUB-1000: Partial Rational fields use type-owned defaults without changing presence")
  func partialDefaults() throws {
    let zero = Ldtx_Workspace_V4_Rational32.with { $0.den = 2 }
    let one = Ldtx_Workspace_V4_Rational32DefaultOne.with { $0.den = 2 }
    #expect(zero.double == 0 && one.double == 0.5)
    #expect(zero.float == 0 && one.float == 0.5)
    #expect(zero.decimal == 0 && one.decimal == 0.5)
    #expect(zero.num == nil && one.num == nil)
    #expect(
      try Ldtx_Workspace_V4_Rational32DefaultOne(
        serializedBytes: one.serializedData()) == one)
    let numeratorOnly = Ldtx_Workspace_V4_Rational32DefaultOne.with { $0.num = -3 }
    #expect(numeratorOnly.double == -3 && numeratorOnly.den == nil)
  }

  @Test("LUB-1000: Conversions preserve absence")
  func conversionsPreserveTheRepresentedValue() {
    #expect(
      Ldtx_Workspace_V4_Rational32DefaultOne(value: Ldtx_Workspace_V4_Rational32()).num == nil)
    #expect(
      Ldtx_Workspace_V4_Rational32(value: Ldtx_Workspace_V4_Rational32DefaultOne()).num == nil)
  }

  @Test("LUB-1000: Shares decimal encoding and allows zero denominator")
  func sharesDecimalEncodingAndAllowsZeroDenominator() throws {
    var value = Ldtx_Workspace_V4_Rational32DefaultOne()
    try value.set(decimal: Decimal(string: "-1.25")!)
    #expect(value.double == -1.25)
    value.set(num: 0, den: 0)
    #expect(
      value.double.isNaN
        && value.float.isNaN
        && value.decimal.isNaN)
    let restored = try Ldtx_Workspace_V4_Rational32DefaultOne(
      serializedBytes: value.serializedData())
    #expect(restored.num == 0 && restored.den == 0)
    value.set(num: 1, den: 0)
    #expect(value.double == .infinity)
  }
}
