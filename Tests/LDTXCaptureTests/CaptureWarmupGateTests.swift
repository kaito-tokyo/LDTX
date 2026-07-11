// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreVideo
import LDTXCapture
import XCTest

final class CaptureWarmupGateTests: XCTestCase {
    func testVideoPTSControlsWarmupAcrossBoundariesAndTimescales() throws {
        let gate = CaptureWarmupGate(durationSeconds: 1)

        XCTAssertEqual(
            gate.observe(sampleBuffer: try makeVideoSampleBuffer(pts: CMTime(value: 600, timescale: 600)), kind: .video),
            .skipped
        )
        XCTAssertEqual(
            gate.observe(sampleBuffer: try makeVideoSampleBuffer(pts: CMTime(value: 1_199, timescale: 600)), kind: .video),
            .skipped
        )
        XCTAssertEqual(
            gate.observe(sampleBuffer: try makeVideoSampleBuffer(pts: CMTime(value: 48_000 * 2, timescale: 48_000)), kind: .video),
            .opened
        )
        XCTAssertEqual(
            gate.observe(sampleBuffer: try makeVideoSampleBuffer(pts: CMTime(value: 0, timescale: 1)), kind: .video),
            .accepted
        )
    }

    func testAudioAndInvalidVideoDoNotEstablishWarmupAnchor() throws {
        let gate = CaptureWarmupGate(durationSeconds: 1)

        XCTAssertEqual(
            gate.observe(sampleBuffer: try makeVideoSampleBuffer(pts: .zero), kind: .audio),
            .skipped
        )
        XCTAssertEqual(
            gate.observe(sampleBuffer: try makeVideoSampleBuffer(pts: .invalid), kind: .video),
            .skipped
        )
        XCTAssertEqual(
            gate.observe(sampleBuffer: try makeVideoSampleBuffer(pts: CMTime(value: 10, timescale: 10)), kind: .video),
            .skipped
        )
        XCTAssertEqual(
            gate.observe(sampleBuffer: try makeVideoSampleBuffer(pts: CMTime(value: 19, timescale: 10)), kind: .video),
            .skipped
        )
        XCTAssertEqual(
            gate.observe(sampleBuffer: try makeVideoSampleBuffer(pts: CMTime(value: 20, timescale: 10)), kind: .video),
            .opened
        )
    }

    func testZeroDurationAcceptsImmediatelyWithoutPTS() throws {
        let gate = CaptureWarmupGate(durationSeconds: 0)

        XCTAssertEqual(
            gate.observe(sampleBuffer: try makeVideoSampleBuffer(pts: .invalid), kind: .video),
            .accepted
        )
    }

    private func makeVideoSampleBuffer(pts: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                2,
                2,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let imageBuffer = try XCTUnwrap(pixelBuffer)
        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }
}
