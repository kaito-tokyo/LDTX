// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import Testing

@Suite struct Rational32DefaultOneUnitTestSuite {
  @Test func defaultsArePartOfEachType() throws {
    let zero = Ldtx_Workspace_V4_Rational32()
    let one = Ldtx_Workspace_V4_Rational32DefaultOne()
    #expect(zero.double == 0)
    #expect(one.double == 1)
    #expect(one.decimal == 1)
    #expect(!one.hasNumerator && !one.hasDenominator)
    #expect(try one.serializedData().isEmpty)
    let transform = Ldtx_Workspace_V4_BasicTransform()
    #expect(transform.translationX.double == 0)
    #expect(transform.scaleX.double == 1 && transform.scaleY.double == 1)
    #expect(!transform.hasScaleX && !transform.hasScaleY)
    let region = Ldtx_Workspace_V4_VisionRegionOfInterest()
    #expect(region.x.double == 0 && region.y.double == 0)
    #expect(region.width.double == 1 && region.height.double == 1)
    try WorkspaceV4IntegrityValidator.validateRegionOfInterest(region)
  }

  @Test func explicitZeroRoundTripsAndClearsBackToOne() throws {
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.scaleX = .with { $0.numerator = 0 }
    let restored = try Ldtx_Workspace_V4_BasicTransform(serializedBytes: transform.serializedData())
    #expect(restored.hasScaleX)
    #expect(restored.scaleX.double == 0)
    transform.clearScaleX()
    #expect(transform.scaleX.double == 1)
    #expect(!transform.hasScaleX)
  }

  @Test func conversionsPreserveTheRepresentedValue() {
    #expect(
      Ldtx_Workspace_V4_Rational32DefaultOne(value: Ldtx_Workspace_V4_Rational32()).double == 0)
    #expect(
      Ldtx_Workspace_V4_Rational32(value: Ldtx_Workspace_V4_Rational32DefaultOne()).double == 1)
  }

  @Test func sharesDecimalEncodingAndAllowsZeroDenominator() throws {
    var value = Ldtx_Workspace_V4_Rational32DefaultOne()
    try value.set(decimal: Decimal(string: "-1.25")!)
    #expect(value.double == -1.25)
    value.set(num: 0, den: 0)
    #expect(value.double.isNaN && value.float.isNaN && value.decimal.isNaN)
    let restored = try Ldtx_Workspace_V4_Rational32DefaultOne(
      serializedBytes: value.serializedData())
    #expect(restored.numerator == 0 && restored.denominator == 0)
    value.set(num: 1, den: 0)
    #expect(value.double == .infinity)
  }
}
