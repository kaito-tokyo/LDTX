// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import LDTXMediaTiming
import Testing

struct AudioChannelTimelineTests {
    @Test func frameIndexConversionCoversTimescalesRoundingAndNegativePTS() throws {
        let scenarios: [(time: CMTime, sampleRate: Int, expectedFrame: Int64)] = [
            (CMTime(value: 1, timescale: 1), 48_000, 48_000),
            (CMTime(value: 600, timescale: 600), 48_000, 48_000),
            (CMTime(value: 44_100, timescale: 44_100), 48_000, 48_000),
            (CMTime(value: 90_000, timescale: 90_000), 48_000, 48_000),
            (CMTime(value: 1, timescale: 20), 10, 1),
            (CMTime(value: -1, timescale: 20), 10, -1),
            (CMTime(value: -3, timescale: 10), 10, -3)
        ]

        for scenario in scenarios {
            #expect(
                try AudioChannelTimeline.frameIndex(
                    for: scenario.time,
                    sampleRate: scenario.sampleRate
                ) == scenario.expectedFrame,
                "time=\(scenario.time) sampleRate=\(scenario.sampleRate)"
            )
        }

        for invalidTime in [CMTime.invalid, CMTime.indefinite, CMTime.positiveInfinity, CMTime.negativeInfinity] {
            #expect(throws: AudioChannelTimelineError.self) { try AudioChannelTimeline.frameIndex(for: invalidTime) }
        }
        #expect(throws: AudioChannelTimelineError.self) { try AudioChannelTimeline.frameIndex(for: .zero, sampleRate: 0) }
    }

    @Test func rejectsInvalidConfigurationAndUndersizedInput() throws {
        #expect(throws: AudioChannelTimelineError.self) { try AudioChannelTimeline(sampleRate: 0) }
        #expect(throws: AudioChannelTimelineError.self) { try AudioChannelTimeline(channelCount: 0) }
        #expect(throws: AudioChannelTimelineError.self) { try AudioChannelTimeline(capacityFrames: 0) }

        let timeline = try AudioChannelTimeline(sampleRate: 10, channelCount: 2, capacityFrames: 4)
        #expect(throws: AudioChannelTimelineError.self) {
            try timeline.insert(samples: [1, 2], frameCount: 2, presentationTime: .zero)
        }
    }

    @Test func readReturnsInsertedSamplesAtPresentationTime() throws {
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

        #expect(samples == [
            1, 2,
            3, 4,
            5, 6
        ])
    }

    @Test func readFillsGapsWithSilence() throws {
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

        #expect(samples == [
            0, 0,
            0, 0,
            7, 8,
            9, 10,
            0, 0
        ])
    }

    @Test func completeRangeDistinguishesMissingFramesFromValidSilence() throws {
        let timeline = try AudioChannelTimeline(sampleRate: 10, channelCount: 2, capacityFrames: 8)

        try timeline.insert(
            samples: [
                0, 0,
                0, 0
            ],
            frameCount: 2,
            presentationTime: CMTime(value: 3, timescale: 10)
        )

        #expect(try timeline.hasCompleteRange(
            presentationTime: CMTime(value: 3, timescale: 10),
            frameCount: 2
        ))
        #expect(try !timeline.hasCompleteRange(
            presentationTime: CMTime(value: 2, timescale: 10),
            frameCount: 3
        ))
    }

    @Test func readReturnsPartialRangeFromInsertedSamples() throws {
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

        #expect(samples == [
            2, 20,
            3, 30
        ])
    }

    @Test func overlapUsesLaterSamples() throws {
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

        #expect(samples == [
            1, 1,
            20, 20,
            30, 30
        ])
    }

    @Test func oldSamplesAreDroppedAfterOverflow() throws {
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

        #expect(samples == [
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

    @Test func incrementalOverflowKeepsFramesStillInsideWindow() throws {
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

        #expect(samples == [
            0, 0,
            2, 2,
            3, 3,
            4, 4,
            5, 5
        ])
    }

    @Test func partialInsertKeepsOnlyRangeThatFitsCurrentWindow() throws {
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

        #expect(samples == [
            3, 3,
            5, 5,
            6, 6
        ])
    }
}
