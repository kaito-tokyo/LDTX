// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct ProgramFramePacer {
    private var scheduledFrameNanoseconds: UInt64?
    private var intervalNanoseconds: UInt64?

    mutating func delayBeforeNextFrame(
        nowNanoseconds: UInt64,
        frameRate: Int
    ) -> UInt64 {
        let newInterval = 1_000_000_000 / UInt64(max(frameRate, 1))
        guard intervalNanoseconds == newInterval,
              let scheduledFrameNanoseconds else {
            intervalNanoseconds = newInterval
            self.scheduledFrameNanoseconds = nowNanoseconds
            return 0
        }

        var nextFrameNanoseconds = scheduledFrameNanoseconds &+ newInterval
        if nextFrameNanoseconds < nowNanoseconds {
            let overdueNanoseconds = nowNanoseconds - nextFrameNanoseconds
            let skippedIntervals = overdueNanoseconds / newInterval + 1
            nextFrameNanoseconds &+= skippedIntervals * newInterval
        }
        self.scheduledFrameNanoseconds = nextFrameNanoseconds
        return nextFrameNanoseconds - nowNanoseconds
    }
}
