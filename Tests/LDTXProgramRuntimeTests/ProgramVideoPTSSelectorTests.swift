// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Testing

@testable import LDTXProgramRuntime

struct ProgramVideoPTSSelectorTests {
    @Test func noConfiguredMasterUsesTheHostClock() {
        var selector = ProgramVideoPTSSelector()

        guard case let .advanced(presentationTime) = selector.select(
            masterCameraID: nil,
            masterPresentationTime: nil
        ) else {
            Issue.record("An unconfigured master must advance using the host clock")
            return
        }

        #expect(presentationTime.isNumeric)
    }

    @Test func configuredMasterCanEstablishAndAdvanceProgramPTS() {
        var selector = ProgramVideoPTSSelector()
        let firstMasterPTS = CMTime(value: 100, timescale: 60)
        let secondMasterPTS = CMTime(value: 101, timescale: 60)

        #expect(
            selector.select(
                masterCameraID: "master-camera",
                masterPresentationTime: nil
            ) == .waitingForMasterPTS
        )
        #expect(
            selector.select(
                masterCameraID: "master-camera",
                masterPresentationTime: firstMasterPTS
            ) == .advanced(firstMasterPTS)
        )
        #expect(
            selector.select(
                masterCameraID: "master-camera",
                masterPresentationTime: secondMasterPTS
            ) == .advanced(secondMasterPTS)
        )
    }

    @Test func missingRepeatedAndBackwardMasterPTSDoNotAdvance() {
        var selector = ProgramVideoPTSSelector()
        let lastPTS = CMTime(value: 100, timescale: 60)
        #expect(selector.select(masterCameraID: "master-camera", masterPresentationTime: lastPTS) == .advanced(lastPTS))

        #expect(selector.select(masterCameraID: "master-camera", masterPresentationTime: nil) == .stalled(lastPTS: lastPTS))
        #expect(selector.select(masterCameraID: "master-camera", masterPresentationTime: lastPTS) == .stalled(lastPTS: lastPTS))
        let backwardPTS = CMTime(value: 99, timescale: 60)
        #expect(selector.select(masterCameraID: "master-camera", masterPresentationTime: backwardPTS) == .rejectedNonMonotonic(lastPTS: lastPTS, receivedPTS: backwardPTS))
        let resumedPTS = CMTime(value: 105, timescale: 60)
        #expect(selector.select(masterCameraID: "master-camera", masterPresentationTime: resumedPTS) == .advanced(resumedPTS))
    }

    @Test func masterSourceChangeRequiresReset() {
        var selector = ProgramVideoPTSSelector()
        let firstPTS = CMTime(value: 10, timescale: 60)
        #expect(selector.select(masterCameraID: "first-camera", masterPresentationTime: firstPTS) == .advanced(firstPTS))
        #expect(
            selector.select(
                masterCameraID: "second-camera",
                masterPresentationTime: CMTime(value: 20, timescale: 60)
            ) == .rejectedMasterSourceChange(expectedKey: "first-camera", receivedKey: "second-camera")
        )

        selector.reset()
        let secondPTS = CMTime(value: 20, timescale: 60)
        #expect(selector.select(masterCameraID: "second-camera", masterPresentationTime: secondPTS) == .advanced(secondPTS))
    }

    @Test func captureSessionChangeStartsANewPTSEpoch() {
        var selector = ProgramVideoPTSSelector()
        let firstSessionID = UUID()
        let secondSessionID = UUID()
        let firstPTS = CMTime(value: 120, timescale: 60)
        let restartedPTS = CMTime(value: 1, timescale: 60)

        #expect(selector.select(
            masterCameraID: "master-camera",
            masterCaptureSessionID: firstSessionID,
            masterPresentationTime: firstPTS
        ) == .advanced(firstPTS))
        #expect(selector.select(
            masterCameraID: "master-camera",
            masterCaptureSessionID: nil,
            masterPresentationTime: nil
        ) == .stalled(lastPTS: firstPTS))
        #expect(selector.select(
            masterCameraID: "master-camera",
            masterCaptureSessionID: secondSessionID,
            masterPresentationTime: restartedPTS
        ) == .advanced(restartedPTS))
    }
}
