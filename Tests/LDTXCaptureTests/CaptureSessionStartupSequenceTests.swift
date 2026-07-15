// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import LDTXCapture

struct CaptureSessionStartupSequenceTests {
    @Test func reappliesVideoConfigurationAfterStartBeforeDeliveringSamples() {
        var events: [String] = []

        CaptureSessionStartupSequence.run(
            start: {
                events.append("start")
            },
            reapplyVideoConfiguration: {
                events.append("reapply")
            },
            enableSampleDelivery: {
                events.append("enable-samples")
            }
        )

        #expect(events == ["start", "reapply", "enable-samples"])
    }

    @Test func doesNotDeliverSamplesWhenReapplyingVideoConfigurationFails() {
        enum TestError: Error, Equatable {
            case reapplyFailed
        }

        var events: [String] = []

        #expect(throws: TestError.reapplyFailed) {
            try CaptureSessionStartupSequence.run(
                start: {
                    events.append("start")
                },
                reapplyVideoConfiguration: {
                    events.append("reapply")
                    throw TestError.reapplyFailed
                },
                enableSampleDelivery: {
                    events.append("enable-samples")
                }
            )
        }

        #expect(events == ["start", "reapply"])
    }
}
