// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import LDTXCapture
import LDTXProgram
import XCTest

@testable import LDTXProgramRuntime

final class ManualCapturePipelineTests: XCTestCase {
    func testManualDeviceDoesNotProduceFramesUntilExplicitlyDriven() async throws {
        let service = ManualCameraCaptureService()
        let recorder = SampleRecorder()

        try await service.startCameraCapture(
            cameraID: "virtual-camera",
            audioDeviceID: nil,
            targetWidth: 320,
            targetHeight: 180,
            frameRate: 60,
            capturesAudio: false,
            configurationHandler: nil
        ) { sampleBuffer, kind in
            recorder.append(sampleBuffer, kind: kind)
        }

        XCTAssertEqual(recorder.count, 0)
        XCTAssertEqual(
            service.request,
            ManualCameraCaptureService.Request(
                cameraID: "virtual-camera",
                targetWidth: 320,
                targetHeight: 180,
                frameRate: 60,
                capturesAudio: false
            )
        )

        let sampleBuffer = try XCTUnwrap(service.emitVideo(frameIndex: 7))

        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(recorder.kinds, [.video])
        XCTAssertEqual(
            sampleBuffer.presentationTimeStamp,
            CMTime(value: 7, timescale: 60)
        )

        XCTAssertNotNil(try service.scheduleVideo(frameIndex: 8, atNanoseconds: 25_000_000))
        XCTAssertNotNil(try service.scheduleVideo(frameIndex: 9, atNanoseconds: 25_000_000))
        XCTAssertEqual(service.advance(toNanoseconds: 24_999_999), 0)
        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(service.advance(toNanoseconds: 25_000_000), 2)
        XCTAssertEqual(
            recorder.presentationTimes,
            [
                CMTime(value: 7, timescale: 60),
                CMTime(value: 8, timescale: 60),
                CMTime(value: 9, timescale: 60)
            ]
        )

        await service.stop()
        XCTAssertNil(service.request)
        XCTAssertNil(try service.emitVideo(frameIndex: 8))
        XCTAssertEqual(recorder.count, 3)
    }

    func testCoordinatorUsesPTSFromManuallyDeliveredDeviceFrames() async throws {
        let service = ManualCameraCaptureService()
        let coordinator = WorkspaceCaptureSessionCoordinator(
            captureServiceFactory: { service }
        )
        var ticks = await coordinator.tickStream().makeAsyncIterator()
        let initialTick = await ticks.next()
        XCTAssertEqual(initialTick, 0)

        let failedCameraIDs = await coordinator.synchronizeInputDeviceCaptures(
            inputDevices: [
                ProgramInputDeviceRecord(
                    name: "Virtual camera",
                    kind: .video,
                    physicalDeviceID: "virtual-camera"
                )
            ],
            availableCameraIDs: ["virtual-camera"],
            canvasWidth: 320,
            canvasHeight: 180,
            frameRate: 60
        )
        XCTAssertEqual(failedCameraIDs, [])

        XCTAssertNotNil(try service.scheduleVideo(frameIndex: 3, atNanoseconds: 50_000_000))
        XCTAssertNotNil(try service.scheduleVideo(frameIndex: 9, atNanoseconds: 150_000_000))
        XCTAssertEqual(service.advance(toNanoseconds: 49_000_000), 0)
        XCTAssertEqual(service.advance(toNanoseconds: 50_000_000), 1)
        let firstTick = await ticks.next()
        XCTAssertEqual(firstTick, 1)
        let firstFrameValue = await coordinator.latestFrame(
            forCameraID: "virtual-camera",
            removesBackground: false
        )
        let firstFrame = try XCTUnwrap(firstFrameValue)
        XCTAssertEqual(firstFrame.sourcePresentationTime, CMTime(value: 3, timescale: 60))

        // Advancing the virtual delivery clock models delayed or dropped device
        // frames without sleeping or coupling delivery time to sample PTS.
        XCTAssertEqual(service.advance(toNanoseconds: 149_000_000), 0)
        XCTAssertEqual(service.advance(toNanoseconds: 150_000_000), 1)
        let secondTick = await ticks.next()
        XCTAssertEqual(secondTick, 2)
        let secondFrameValue = await coordinator.latestFrame(
            forCameraID: "virtual-camera",
            removesBackground: false
        )
        let secondFrame = try XCTUnwrap(secondFrameValue)
        XCTAssertEqual(secondFrame.sourcePresentationTime, CMTime(value: 9, timescale: 60))
        XCTAssertEqual(
            secondFrame.sourcePresentationTime - firstFrame.sourcePresentationTime,
            CMTime(value: 6, timescale: 60)
        )

        await coordinator.stop()
    }
}

private final class SampleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(CMSampleBuffer, CameraCaptureSampleKind)] = []

    var count: Int {
        lock.withLock { samples.count }
    }

    var kinds: [CameraCaptureSampleKind] {
        lock.withLock { samples.map(\.1) }
    }

    var presentationTimes: [CMTime] {
        lock.withLock { samples.map { $0.0.presentationTimeStamp } }
    }

    func append(_ sampleBuffer: CMSampleBuffer, kind: CameraCaptureSampleKind) {
        lock.withLock {
            samples.append((sampleBuffer, kind))
        }
    }
}
