// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LDTXCapture

final class CaptureSessionStartupSequenceTests: XCTestCase {
    func testReappliesVideoConfigurationAfterStartBeforeDeliveringSamples() {
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

        XCTAssertEqual(events, ["start", "reapply", "enable-samples"])
    }

    func testDoesNotDeliverSamplesWhenReapplyingVideoConfigurationFails() {
        enum TestError: Error {
            case reapplyFailed
        }

        var events: [String] = []

        XCTAssertThrowsError(
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
        )

        XCTAssertEqual(events, ["start", "reapply"])
    }
}
