// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import LDTXProgramRuntime

final class ProgramAudioInputPassthroughTests: XCTestCase {
    func testGainIsAppliedByAVAudioEngineGainUnit() {
        let state = ProgramAudioInputPassthroughChannelState(linearGain: 0.1)

        XCTAssertEqual(state.gainDecibels, -20, accuracy: 0.0001)

        state.setGain(linearGain: 5)

        XCTAssertEqual(state.gainDecibels, 20 * log10(5), accuracy: 0.0001)
    }

    func testGainUnitClampsToSupportedProgramRange() {
        let state = ProgramAudioInputPassthroughChannelState(linearGain: 0)

        XCTAssertEqual(state.gainDecibels, -80, accuracy: 0.0001)

        state.setGain(linearGain: 100)

        XCTAssertEqual(state.gainDecibels, 20, accuracy: 0.0001)
    }
}
