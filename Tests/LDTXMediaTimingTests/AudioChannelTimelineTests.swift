// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import LDTXMediaTiming
import XCTest

final class AudioChannelTimelineTests: XCTestCase {
    func testReadReturnsInsertedSamplesAtPresentationTime() throws {
        let timeline = try AudioChannelTimeline(sampleRate: 10, channelCount: 2, capacityFrames: 8)

        try timeline.insert(
            samples: [
                1, 2,
                3, 4,
                5, 6
            ],
            frameCount: 3,
            presentationTime: CMTime(value: 2, timescale: 10)
        )

        let samples = try timeline.read(
            presentationTime: CMTime(value: 2, timescale: 10),
            frameCount: 3
        )

        XCTAssertEqual(samples, [
            1, 2,
            3, 4,
            5, 6
        ])
    }

    func testReadFillsGapsWithSilence() throws {
        let timeline = try AudioChannelTimeline(sampleRate: 10, channelCount: 2, capacityFrames: 8)

        try timeline.insert(
            samples: [
                7, 8,
                9, 10
            ],
            frameCount: 2,
            presentationTime: CMTime(value: 3, timescale: 10)
        )

        let samples = try timeline.read(
            presentationTime: CMTime(value: 1, timescale: 10),
            frameCount: 5
        )

        XCTAssertEqual(samples, [
            0, 0,
            0, 0,
            7, 8,
            9, 10,
            0, 0
        ])
    }

    func testReadReturnsPartialRangeFromInsertedSamples() throws {
        let timeline = try AudioChannelTimeline(sampleRate: 10, channelCount: 2, capacityFrames: 8)

        try timeline.insert(
            samples: [
                1, 10,
                2, 20,
                3, 30,
                4, 40
            ],
            frameCount: 4,
            presentationTime: CMTime(value: 2, timescale: 10)
        )

        let samples = try timeline.read(
            presentationTime: CMTime(value: 3, timescale: 10),
            frameCount: 2
        )

        XCTAssertEqual(samples, [
            2, 20,
            3, 30
        ])
    }

    func testOverlapUsesLaterSamples() throws {
        let timeline = try AudioChannelTimeline(sampleRate: 10, channelCount: 2, capacityFrames: 8)

        try timeline.insert(
            samples: [
                1, 1,
                2, 2,
                3, 3
            ],
            frameCount: 3,
            presentationTime: CMTime(value: 0, timescale: 10)
        )
        try timeline.insert(
            samples: [
                20, 20,
                30, 30
            ],
            frameCount: 2,
            presentationTime: CMTime(value: 1, timescale: 10)
        )

        let samples = try timeline.read(
            presentationTime: CMTime(value: 0, timescale: 10),
            frameCount: 3
        )

        XCTAssertEqual(samples, [
            1, 1,
            20, 20,
            30, 30
        ])
    }

    func testOldSamplesAreDroppedAfterOverflow() throws {
        let timeline = try AudioChannelTimeline(sampleRate: 10, channelCount: 2, capacityFrames: 4)

        try timeline.insert(
            samples: [
                1, 1,
                2, 2,
                3, 3,
                4, 4
            ],
            frameCount: 4,
            presentationTime: CMTime(value: 0, timescale: 10)
        )
        try timeline.insert(
            samples: [
                5, 5,
                6, 6,
                7, 7,
                8, 8
            ],
            frameCount: 4,
            presentationTime: CMTime(value: 4, timescale: 10)
        )

        let samples = try timeline.read(
            presentationTime: CMTime(value: 0, timescale: 10),
            frameCount: 8
        )

        XCTAssertEqual(samples, [
            0, 0,
            0, 0,
            0, 0,
            0, 0,
            5, 5,
            6, 6,
            7, 7,
            8, 8
        ])
    }

    func testIncrementalOverflowKeepsFramesStillInsideWindow() throws {
        let timeline = try AudioChannelTimeline(sampleRate: 10, channelCount: 2, capacityFrames: 4)

        try timeline.insert(
            samples: [
                1, 1,
                2, 2,
                3, 3,
                4, 4
            ],
            frameCount: 4,
            presentationTime: CMTime(value: 0, timescale: 10)
        )
        try timeline.insert(
            samples: [
                5, 5
            ],
            frameCount: 1,
            presentationTime: CMTime(value: 4, timescale: 10)
        )

        let samples = try timeline.read(
            presentationTime: CMTime(value: 0, timescale: 10),
            frameCount: 5
        )

        XCTAssertEqual(samples, [
            0, 0,
            2, 2,
            3, 3,
            4, 4,
            5, 5
        ])
    }

    func testPartialInsertKeepsOnlyRangeThatFitsCurrentWindow() throws {
        let timeline = try AudioChannelTimeline(sampleRate: 10, channelCount: 2, capacityFrames: 4)

        try timeline.insert(
            samples: [
                4, 4,
                5, 5,
                6, 6,
                7, 7
            ],
            frameCount: 4,
            presentationTime: CMTime(value: 4, timescale: 10)
        )
        try timeline.insert(
            samples: [
                1, 1,
                2, 2,
                3, 3
            ],
            frameCount: 3,
            presentationTime: CMTime(value: 2, timescale: 10)
        )

        let samples = try timeline.read(
            presentationTime: CMTime(value: 4, timescale: 10),
            frameCount: 3
        )

        XCTAssertEqual(samples, [
            3, 3,
            5, 5,
            6, 6
        ])
    }
}
