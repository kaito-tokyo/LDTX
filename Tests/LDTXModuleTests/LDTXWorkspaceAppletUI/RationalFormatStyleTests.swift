// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

@Suite("Rational numeric editing", .tags(.medium))
struct RationalFormatStyleUnitTestSuite {
  @Test("LUB-1048: Parses and formats exact values") func parsesAndFormatsExactValues() throws {
    let parser = RationalParseStrategy()
    let value = try parser.parse("0.125")
    #expect(value.num == 1)
    #expect(value.den == 8)
    #expect(RationalFormatStyle().format(value) == "0.125")
    #expect(try parser.parse("1.25e-2").den == 80)
    #expect(try parser.parse("-2147483648").num == Int32.min)
  }

  @Test("LUB-1048: Preserves pixel coordinates") func preservesPixelCoordinates() throws {
    let normalized = try RationalParseStrategy(divisor: 1920).parse("100.125")
    #expect(RationalFormatStyle(multiplier: 1920).format(normalized) == "100.125")
    let decoded = try Ldtx_Workspace_V4_Rational32(serializedBytes: normalized.serializedData())
    #expect(decoded == normalized)
    #expect(RationalFormatStyle().format(try RationalParseStrategy().parse("1/3")) == "1/3")
  }

  @Test("LUB-1048: Rejects invalid input") func rejectsInvalidInput() {
    for input in ["1/0", "nan", "1e38", "2147483648", "-2147483649", "1/4294967296"] {
      #expect(throws: RationalInputError.self) { try RationalParseStrategy().parse(input) }
    }
  }
  @Test("LUB-1048: Continuous sliders use explicit precision")
  func continuousSlidersUseExplicitPrecision() throws {
    var value = Ldtx_Workspace_V4_Rational32()
    let binding = Binding(get: { value }, set: { value = $0 }).sliderValue(denominator: 1_000_000)
    for input in [0.123456789, Double.pi, 2 * Double.pi] {
      binding.wrappedValue = input
      #expect(abs(value.double(defaultNumerator: 0, defaultDenominator: 1) - input) <= 0.0000005)
      #expect(value.den == 1_000_000)
    }
    let previous = value
    for input in [Double.nan, .infinity, Double.greatestFiniteMagnitude] {
      binding.wrappedValue = input
      #expect(value == previous)
    }
    let gain = try RationalSliderEncoding.encode(-11.899999999999999, denominator: 10)
    #expect(gain.num == -119)
    #expect(gain.den == 10)
  }

}
