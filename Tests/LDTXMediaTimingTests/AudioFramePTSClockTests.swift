// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import LDTXMediaTiming
import XCTest

final class AudioFramePTSClockTests: XCTestCase {
    func testRejectsInvalidConfigurationAndFrameCounts() throws {
        XCTAssertThrowsError(try AudioFramePTSClock(sampleRate: 0))

        let clock = try AudioFramePTSClock(sampleRate: 48_000)
        XCTAssertThrowsError(try clock.nextPresentationTime(
            anchorPresentationTime: .zero,
            frameCount: 0
        ))
        XCTAssertThrowsError(try clock.nextPresentationTime(
            anchorPresentationTime: .zero,
            frameCount: -1
        ))
    }

    func testStartsAtAnchorPresentationTime() throws {
        let clock = try AudioFramePTSClock(sampleRate: 10)

        let presentationTime = try clock.nextPresentationTime(
            anchorPresentationTime: CMTime(value: 25, timescale: 10),
            frameCount: 3
        )

        XCTAssertEqual(presentationTime, CMTime(value: 25, timescale: 10))
    }

    func testAdvancesByReceivedFrameCountIgnoringLaterAnchors() throws {
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

        XCTAssertEqual(first, CMTime(value: 25, timescale: 10))
        XCTAssertEqual(second, CMTime(value: 28, timescale: 10))
        XCTAssertEqual(third, CMTime(value: 30, timescale: 10))
    }

    func testInvalidFirstAnchorThrows() throws {
        let clock = try AudioFramePTSClock(sampleRate: 10)

        XCTAssertThrowsError(try clock.nextPresentationTime(
            anchorPresentationTime: .invalid,
            frameCount: 3
        ))
    }

    func testInvalidLaterAnchorIsIgnoredAfterTimelineStarts() throws {
        let clock = try AudioFramePTSClock(sampleRate: 10)

        _ = try clock.nextPresentationTime(
            anchorPresentationTime: CMTime(value: 25, timescale: 10),
            frameCount: 3
        )
        let presentationTime = try clock.nextPresentationTime(
            anchorPresentationTime: .invalid,
            frameCount: 2
        )

        XCTAssertEqual(presentationTime, CMTime(value: 28, timescale: 10))
    }

    func testLongIrregularSequenceHasNoCumulativeDrift() throws {
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

            XCTAssertEqual(
                presentationTime,
                CMTime(value: expectedFrameIndex, timescale: CMTimeScale(sampleRate)),
                "bufferIndex=\(bufferIndex)"
            )
            expectedFrameIndex += CMTimeValue(frameCount)
        }
    }
}
