// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import LDTXMediaTiming
import Testing

struct AudioFramePTSClockTests {
    @Test func rejectsInvalidConfigurationAndFrameCounts() throws {
        #expect(throws: AudioChannelTimelineError.self) { try AudioFramePTSClock(sampleRate: 0) }

        let clock = try AudioFramePTSClock(sampleRate: 48_000)
        #expect(throws: AudioChannelTimelineError.self) {
            try clock.nextPresentationTime(anchorPresentationTime: .zero, frameCount: 0)
        }
        #expect(throws: AudioChannelTimelineError.self) {
            try clock.nextPresentationTime(anchorPresentationTime: .zero, frameCount: -1)
        }
    }

    @Test func startsAtAnchorPresentationTime() throws {
        let clock = try AudioFramePTSClock(sampleRate: 10)

        let presentationTime = try clock.nextPresentationTime(
            anchorPresentationTime: CMTime(value: 25, timescale: 10),
            frameCount: 3
        )

        #expect(presentationTime == CMTime(value: 25, timescale: 10))
    }

    @Test func advancesByReceivedFrameCountIgnoringLaterAnchors() throws {
        let clock = try AudioFramePTSClock(sampleRate: 10)

        let first = try clock.nextPresentationTime(
            anchorPresentationTime: CMTime(value: 25, timescale: 10),
            frameCount: 3
        )
        let second = try clock.nextPresentationTime(
            anchorPresentationTime: CMTime(value: 99, timescale: 10),
            frameCount: 2
        )
        let third = try clock.nextPresentationTime(
            anchorPresentationTime: CMTime(value: 20, timescale: 10),
            frameCount: 4
        )

        #expect(first == CMTime(value: 25, timescale: 10))
        #expect(second == CMTime(value: 28, timescale: 10))
        #expect(third == CMTime(value: 30, timescale: 10))
    }

    @Test func invalidFirstAnchorThrows() throws {
        let clock = try AudioFramePTSClock(sampleRate: 10)

        #expect(throws: AudioChannelTimelineError.self) {
            try clock.nextPresentationTime(anchorPresentationTime: .invalid, frameCount: 3)
        }
    }

    @Test func invalidLaterAnchorIsIgnoredAfterTimelineStarts() throws {
        let clock = try AudioFramePTSClock(sampleRate: 10)

        _ = try clock.nextPresentationTime(
            anchorPresentationTime: CMTime(value: 25, timescale: 10),
            frameCount: 3
        )
        let presentationTime = try clock.nextPresentationTime(
            anchorPresentationTime: .invalid,
            frameCount: 2
        )

        #expect(presentationTime == CMTime(value: 28, timescale: 10))
    }

    @Test func longIrregularSequenceHasNoCumulativeDrift() throws {
        let sampleRate = 48_000
        let anchor = CMTime(value: 52_655 * CMTimeValue(sampleRate), timescale: CMTimeScale(sampleRate))
        let clock = try AudioFramePTSClock(sampleRate: sampleRate)
        let frameCounts = [1, 160, 441, 960, 1_024, 2_047]
        var expectedFrameIndex = anchor.value

        for bufferIndex in 0..<100_000 {
            let frameCount = frameCounts[bufferIndex % frameCounts.count]
            let presentationTime = try clock.nextPresentationTime(
                anchorPresentationTime: bufferIndex == 0 ? anchor : CMTime(value: -999, timescale: 1),
                frameCount: frameCount
            )

            #expect(
                presentationTime == CMTime(value: expectedFrameIndex, timescale: CMTimeScale(sampleRate)),
                "bufferIndex=\(bufferIndex)"
            )
            expectedFrameIndex += CMTimeValue(frameCount)
        }
    }
}
