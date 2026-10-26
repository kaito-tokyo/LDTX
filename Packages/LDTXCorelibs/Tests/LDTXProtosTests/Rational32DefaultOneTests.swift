// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
import Testing

@Suite struct Rational32DefaultOneUnitTestSuite {
  @Test("LUB-1000: Defaults are part of each type") func defaultsArePartOfEachType() throws {
    let zero = Ldtx_Workspace_V4_Rational32()
    let one = Ldtx_Workspace_V4_Rational32DefaultOne()
    #expect(zero.double == 0)
    #expect(one.double == 1)
    #expect(one.decimal == 1)
    #expect(!one.hasNum && !one.hasDen)
    #expect(try one.serializedData().isEmpty)
    let transform = Ldtx_Workspace_V4_BasicTransform()
    #expect(transform.translationX.double == 0)
    #expect(transform.scaleX.double == 1 && transform.scaleY.double == 1)
    #expect(!transform.hasScaleX && !transform.hasScaleY)
    let region = Ldtx_Workspace_V4_VisionRegionOfInterest()
    #expect(region.x.double == 0 && region.y.double == 0)
    #expect(region.width.double == 1 && region.height.double == 1)
    try WorkspaceBundleValidatorV4.validateRegionOfInterest(region)
  }

  @Test("LUB-1000: Conversions preserve the represented value")
  func conversionsPreserveTheRepresentedValue() {
    #expect(
      Ldtx_Workspace_V4_Rational32DefaultOne(value: Ldtx_Workspace_V4_Rational32()).double == 0)
    #expect(
      Ldtx_Workspace_V4_Rational32(value: Ldtx_Workspace_V4_Rational32DefaultOne()).double == 1)
  }

  @Test("LUB-1000: Shares decimal encoding and allows zero denominator")
  func sharesDecimalEncodingAndAllowsZeroDenominator() throws {
    var value = Ldtx_Workspace_V4_Rational32DefaultOne()
    try value.set(decimal: Decimal(string: "-1.25")!)
    #expect(value.double == -1.25)
    value.set(num: 0, den: 0)
    #expect(value.double.isNaN && value.float.isNaN && value.decimal.isNaN)
    let restored = try Ldtx_Workspace_V4_Rational32DefaultOne(
      serializedBytes: value.serializedData())
    #expect(restored.num == 0 && restored.den == 0)
    value.set(num: 1, den: 0)
    #expect(value.double == .infinity)
  }
}
