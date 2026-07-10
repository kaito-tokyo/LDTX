// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@testable import LDTXProgramRuntime
import Testing

struct ProgramFramePacerTests {
    @Test
    func renderingTimeIsSubtractedFromFrameInterval() {
        var pacer = ProgramFramePacer()

        #expect(pacer.delayBeforeNextFrame(nowNanoseconds: 0, frameRate: 60) == 0)
        #expect(
            pacer.delayBeforeNextFrame(nowNanoseconds: 4_000_000, frameRate: 60)
                == 12_666_666
        )
        #expect(
            pacer.delayBeforeNextFrame(nowNanoseconds: 20_000_000, frameRate: 60)
                == 13_333_332
        )
    }

    @Test
    func missedDeadlineSkipsAheadWithoutCatchUpBurst() {
        var pacer = ProgramFramePacer()

        #expect(pacer.delayBeforeNextFrame(nowNanoseconds: 0, frameRate: 60) == 0)
        #expect(
            pacer.delayBeforeNextFrame(nowNanoseconds: 20_000_000, frameRate: 60)
                == 13_333_332
        )
    }

    @Test
    func exactDeadlineRendersImmediately() {
        var pacer = ProgramFramePacer()

        #expect(pacer.delayBeforeNextFrame(nowNanoseconds: 0, frameRate: 60) == 0)
        #expect(
            pacer.delayBeforeNextFrame(nowNanoseconds: 16_666_666, frameRate: 60) == 0
        )
    }

    @Test
    func frameRateChangeResetsSchedule() {
        var pacer = ProgramFramePacer()

        #expect(pacer.delayBeforeNextFrame(nowNanoseconds: 1_000, frameRate: 60) == 0)
        #expect(pacer.delayBeforeNextFrame(nowNanoseconds: 2_000, frameRate: 30) == 0)
    }
}
