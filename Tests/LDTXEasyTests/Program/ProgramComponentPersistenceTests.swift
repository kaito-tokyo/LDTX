// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import Testing

@Suite
struct ProgramComponentPersistenceUnitTestSuite {
  @Test func inputDestinationDecodesLegacyUniformScale() throws {
    let data = Data(#"{"x":120,"y":80,"scale":1.5}"#.utf8)

    let destination = try JSONDecoder().decode(InputDeviceDestination.self, from: data)

    #expect(destination.x == 120)
    #expect(destination.y == 80)
    #expect(destination.scaleX == 1.5)
    #expect(destination.scaleY == 1.5)
  }

  @Test func clockCSSBackgroundValidationUsesRenderingGrammar() throws {
    #expect(ClockCSSBackground.isValid(""))
    #expect(ClockCSSBackground.isValid("#10203080"))
    #expect(ClockCSSBackground.isValid("rgba(16, 32, 48, 0.5)"))
    #expect(ClockCSSBackground.isValid("linear-gradient(90deg, #102030, transparent)"))
    #expect(!ClockCSSBackground.isValid("not-a-background"))
    #expect(!ClockCSSBackground.isValid("linear-gradient(nandeg, #000, #fff)"))
    #expect(!ClockCSSBackground.isValid("linear-gradient(infdeg, #000, #fff)"))

    let empty = try #require(ClockCSSBackground.parse(""))
    #expect(empty == .solid(.clear))
  }

}
