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
  @Test("LUB-1000: Defaults are supplied by the caller") func defaultsAreSuppliedByCaller() throws {
    let zero = Ldtx_Workspace_V4_Rational32()
    let one = Ldtx_Workspace_V4_Rational32DefaultOne()
    #expect(zero.double(defaultNumerator: 0, defaultDenominator: 1) == 0)
    #expect(one.double(defaultNumerator: 1, defaultDenominator: 1) == 1)
    #expect(one.decimal(defaultNumerator: 1, defaultDenominator: 1) == 1)
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
    #expect(value.double(defaultNumerator: 1, defaultDenominator: 1) == -1.25)
    value.set(num: 0, den: 0)
    #expect(
      value.double(defaultNumerator: 1, defaultDenominator: 1).isNaN
        && value.float(defaultNumerator: 1, defaultDenominator: 1).isNaN
        && value.decimal(defaultNumerator: 1, defaultDenominator: 1).isNaN)
    let restored = try Ldtx_Workspace_V4_Rational32DefaultOne(
      serializedBytes: value.serializedData())
    #expect(restored.num == 0 && restored.den == 0)
    value.set(num: 1, den: 0)
    #expect(value.double(defaultNumerator: 1, defaultDenominator: 1) == .infinity)
  }
}
