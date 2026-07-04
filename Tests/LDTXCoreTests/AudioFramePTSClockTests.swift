// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import LDTXMedia
import XCTest

final class AudioFramePTSClockTests: XCTestCase {
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
}
