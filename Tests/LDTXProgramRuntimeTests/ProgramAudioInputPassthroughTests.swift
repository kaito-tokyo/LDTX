// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import LDTXProgramRuntime

struct ProgramAudioInputPassthroughTests {
  @Test func gainIsAppliedByAVAudioEngineGainUnit() {
    let state = ProgramAudioInputPassthroughChannelState(linearGain: 0.1)

    #expect(abs(state.gainDecibels - -20) <= 0.0001)

    state.setGain(linearGain: 5)

    #expect(abs(state.gainDecibels - 20 * log10(5)) <= 0.0001)
  }

  @Test func gainUnitClampsToSupportedProgramRange() {
    let state = ProgramAudioInputPassthroughChannelState(linearGain: 0)

    #expect(abs(state.gainDecibels - -80) <= 0.0001)

    state.setGain(linearGain: 100)

    #expect(abs(state.gainDecibels - 20) <= 0.0001)
  }
}
