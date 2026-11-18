// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LDTXAudioKit

final class LDTXAudioKitTests: XCTestCase {
  func testAudioEngineCanBeCreatedWithoutHardware() {
    let engine = AudioEngine(hardwareEnabled: false)
    XCTAssertNotNil(engine)
  }
}
