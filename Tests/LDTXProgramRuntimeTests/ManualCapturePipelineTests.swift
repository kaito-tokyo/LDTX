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

        try await withCheckedThrowingContinuation { continuation in
            service.startCameraCapture(
                cameraID: "virtual-camera",
                audioDeviceID: nil,
                targetWidth: 320,
                targetHeight: 180,
                frameRate: 60,
                capturesAudio: false,
                configurationHandler: nil,
                handler: { sampleBuffer, kind in
                    recorder.append(sampleBuffer, kind: kind)
                },
                completionHandler: { result in
                    continuation.resume(with: result)
                }
            )
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

        service.stop()
        XCTAssertNil(service.request)
        XCTAssertNil(try service.emitVideo(frameIndex: 8))
        XCTAssertEqual(recorder.count, 3)
    }

    func testCoordinatorUsesPTSFromManuallyDeliveredDeviceFrames() async throws {
        let service = ManualCameraCaptureService()
        let coordinator = WorkspaceCaptureSessionCoordinator(
            captureServiceFactory: { service }
        )
        let ticks = TickRecorder()
        let tickObserverID = coordinator.addTickHandler { tick in
            ticks.append(tick)
        }
        XCTAssertEqual(ticks.values, [0])

        let failedCameraIDs: Set<String> = await withCheckedContinuation { continuation in
            coordinator.synchronizeInputDeviceCaptures(
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
                frameRate: 60,
                completionHandler: { failedCameraIDs in
                    continuation.resume(returning: failedCameraIDs)
                }
            )
        }
        XCTAssertEqual(failedCameraIDs, [])

        XCTAssertNotNil(try service.scheduleVideo(frameIndex: 3, atNanoseconds: 50_000_000))
        XCTAssertNotNil(try service.scheduleVideo(frameIndex: 9, atNanoseconds: 150_000_000))
        XCTAssertEqual(service.advance(toNanoseconds: 49_000_000), 0)
        XCTAssertEqual(service.advance(toNanoseconds: 50_000_000), 1)
        await fulfillment(of: [ticks.expect(1)], timeout: 1)
        let firstFrameValue = coordinator.latestFrame(
            forCameraID: "virtual-camera",
            removesBackground: false
        )
        let firstFrame = try XCTUnwrap(firstFrameValue)
        XCTAssertEqual(firstFrame.sourcePresentationTime, CMTime(value: 3, timescale: 60))

        // Advancing the virtual delivery clock models delayed or dropped device
        // frames without sleeping or coupling delivery time to sample PTS.
        XCTAssertEqual(service.advance(toNanoseconds: 149_000_000), 0)
        XCTAssertEqual(service.advance(toNanoseconds: 150_000_000), 1)
        await fulfillment(of: [ticks.expect(2)], timeout: 1)
        let secondFrameValue = coordinator.latestFrame(
            forCameraID: "virtual-camera",
            removesBackground: false
        )
        let secondFrame = try XCTUnwrap(secondFrameValue)
        XCTAssertEqual(secondFrame.sourcePresentationTime, CMTime(value: 9, timescale: 60))
        XCTAssertEqual(
            secondFrame.sourcePresentationTime - firstFrame.sourcePresentationTime,
            CMTime(value: 6, timescale: 60)
        )

        coordinator.removeTickHandler(tickObserverID)
        await withCheckedContinuation { continuation in
            coordinator.stop {
                continuation.resume()
            }
        }
    }
}

private final class TickRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [UInt64] = []
    private var expectationsByValue: [UInt64: [XCTestExpectation]] = [:]

    var values: [UInt64] {
        lock.withLock { recordedValues }
    }

    func append(_ value: UInt64) {
        let expectations = lock.withLock { () -> [XCTestExpectation] in
            recordedValues.append(value)
            return expectationsByValue.removeValue(forKey: value) ?? []
        }
        expectations.forEach { $0.fulfill() }
    }

    func expect(_ value: UInt64) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "tick \(value)")
        let alreadyRecorded = lock.withLock { () -> Bool in
            if recordedValues.contains(value) {
                return true
            }
            expectationsByValue[value, default: []].append(expectation)
            return false
        }
        if alreadyRecorded {
            expectation.fulfill()
        }
        return expectation
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
