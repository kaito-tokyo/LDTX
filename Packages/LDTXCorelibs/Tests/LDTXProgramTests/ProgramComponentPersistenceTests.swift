// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
import Testing

@Suite
struct ProgramComponentPersistenceUnitTestSuite {
  @Test("LUB-1001: Input destination decodes legacy uniform scale")
  func inputDestinationDecodesLegacyUniformScale() throws {
    let data = Data(#"{"x":120,"y":80,"scale":1.5}"#.utf8)

    let destination = try JSONDecoder().decode(InputDeviceDestination.self, from: data)

    #expect(destination.x == 120)
    #expect(destination.y == 80)
    #expect(destination.scaleX == 1.5)
    #expect(destination.scaleY == 1.5)
  }

  @Test("LUB-1001: Clock outline color parsing") func clockOutlineColorParsing() {
    #expect(ClockOutlineColor.parse("#10203080") != nil)
    #expect(ClockOutlineColor.parse("rgba(16, 32, 48, 0.5)") != nil)
    #expect(ClockOutlineColor.parse("transparent") == .clear)
    #expect(ClockOutlineColor.parse("invalid") == nil)
  }

}
