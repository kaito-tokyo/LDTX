// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXMessages
import Testing

#if os(Linux)
  import FoundationEssentials
#else
  import Foundation
#endif

@Suite
struct EditionCompatibilityUnitTestSuite {
  @Test("LUB-1000: Clock font size uses new tag and discards reserved fields")
  func clockFontSizeUsesNewTagAndDiscardsReservedFields() throws {
    // Former width/height fields are no longer interpreted as Clock geometry.
    let legacy = Data([
      0x1a, 0x04, 0x08, 0x02, 0x10, 0x0c,
      0x22, 0x04, 0x08, 0x04, 0x10, 0x36, 0x52, 0x00,
    ])
    var clock = try Ldtx_Workspace_V4_ClockComponent(serializedBytes: legacy)
    #expect((clock.fontSize == nil))
    #expect(try clock.serializedData().isEmpty)
    clock.fontSize = .with { $0.set(num: 48, den: 1) }
    let restored = try Ldtx_Workspace_V4_ClockComponent(serializedBytes: clock.serializedData())
    #expect(restored.fontSize?.double(defaultNumerator: 0, defaultDenominator: 1) == 48)
    #expect(restored == clock)
    #expect(try clock.serializedData().contains(0x62))  // field 12, length-delimited
  }
}
