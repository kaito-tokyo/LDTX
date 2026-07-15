// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Testing

@testable import LDTXProgramRuntime

struct ProgramVideoPTSSelectorTests {
    @Test func onlyConfiguredMasterCanEstablishAndAdvanceProgramPTS() {
        var selector = ProgramVideoPTSSelector()
        let firstMasterPTS = CMTime(value: 100, timescale: 60)
        let secondMasterPTS = CMTime(value: 101, timescale: 60)

        #expect(
            selector.select(
                masterKey: "master",
                presentationTimesByInputKey: ["secondary": CMTime(value: 1_000, timescale: 60)]
            ) == .waitingForMasterPTS
        )
        #expect(
            selector.select(
                masterKey: "master",
                presentationTimesByInputKey: [
                    "master": firstMasterPTS,
                    "secondary": CMTime(value: 2_000, timescale: 60)
                ]
            ) == .advanced(firstMasterPTS)
        )
        #expect(
            selector.select(
                masterKey: "master",
                presentationTimesByInputKey: [
                    "master": secondMasterPTS,
                    "secondary": CMTime(value: 50, timescale: 60)
                ]
            ) == .advanced(secondMasterPTS)
        )
    }

    @Test func missingRepeatedAndBackwardMasterPTSDoNotAdvance() {
        var selector = ProgramVideoPTSSelector()
        let lastPTS = CMTime(value: 100, timescale: 60)
        #expect(selector.select(masterKey: "master", presentationTimesByInputKey: ["master": lastPTS]) == .advanced(lastPTS))

        #expect(selector.select(masterKey: "master", presentationTimesByInputKey: [:]) == .stalled(lastPTS: lastPTS))
        #expect(selector.select(masterKey: "master", presentationTimesByInputKey: ["master": lastPTS]) == .stalled(lastPTS: lastPTS))
        let backwardPTS = CMTime(value: 99, timescale: 60)
        #expect(selector.select(masterKey: "master", presentationTimesByInputKey: ["master": backwardPTS]) == .rejectedNonMonotonic(lastPTS: lastPTS, receivedPTS: backwardPTS))
        let resumedPTS = CMTime(value: 105, timescale: 60)
        #expect(selector.select(masterKey: "master", presentationTimesByInputKey: ["master": resumedPTS]) == .advanced(resumedPTS))
    }

    @Test func masterSourceChangeRequiresReset() {
        var selector = ProgramVideoPTSSelector()
        let firstPTS = CMTime(value: 10, timescale: 60)
        #expect(selector.select(masterKey: "first", presentationTimesByInputKey: ["first": firstPTS]) == .advanced(firstPTS))
        #expect(
            selector.select(
                masterKey: "second",
                presentationTimesByInputKey: ["second": CMTime(value: 20, timescale: 60)]
            ) == .rejectedMasterSourceChange(expectedKey: "first", receivedKey: "second")
        )

        selector.reset()
        let secondPTS = CMTime(value: 20, timescale: 60)
        #expect(selector.select(masterKey: "second", presentationTimesByInputKey: ["second": secondPTS]) == .advanced(secondPTS))
    }
}
