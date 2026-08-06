// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import LDTXCapture
import LDTXProgram
import LDTXProgramRendering
import XCTest

@testable import LDTXProgramRuntime

final class ManualCapturePipelineTests: XCTestCase {
    func testRuntimeFailureInvalidatesTheLastCapturedFrame() async throws {
        let service = ManualCameraCaptureService()
        let coordinator = WorkspaceCaptureSessionCoordinator(captureServiceFactory: { service })
        let input = ProgramInputDeviceRecord(
            name: "Virtual camera", kind: .video, physicalDeviceID: "virtual-camera"
        )
        let failures: Set<String> = await withCheckedContinuation { continuation in
            coordinator.synchronizeInputDeviceCaptures(
                inputDevices: [input],
                availableCameraIDs: ["virtual-camera"],
                canvasWidth: 320,
                canvasHeight: 180,
                frameRate: 60,
                completionHandler: { continuation.resume(returning: $0) }
            )
        }
        XCTAssertEqual(failures, [])
        _ = try XCTUnwrap(service.emitVideo(frameIndex: 1))
        XCTAssertNotNil(coordinator.latestFrame(forCameraID: "virtual-camera"))

        service.emitRuntimeFailure(.deviceDisconnected(deviceID: "virtual-camera"))

        XCTAssertNil(coordinator.latestFrame(forCameraID: "virtual-camera"))
        await withCheckedContinuation { continuation in
            coordinator.stopAndReset { continuation.resume() }
        }
    }

    func testRendererDoesNotReuseOutputBuffersRetainedByConsumers() throws {
        let renderer = ActiveProgramRenderer(
            captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
            lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(interval: .seconds(60))
        )
        let configuration = ProgramRuntimeConfiguration(
            composite: CompositeProgramDefinition(steps: [
                CompositeProgramStep(component: .fillSolidColor(FillSolidColorComponent()))
            ]),
            audioChannels: [],
            canvasWidth: 320,
            canvasHeight: 180,
            outputWidth: 320,
            outputHeight: 180,
            frameRate: 60,
            timeSeconds: 0,
            videoPTSMasterCameraID: nil,
            cameraIDsByInputKey: [:],
            inputDeviceNamesByInputKey: [:],
            cameraInputColorOverrides: [:],
            backgroundRemovalInputKeys: []
        )
        renderer.beginSession(1)
        defer { renderer.endSession(1) }

        let frames = try (1...4).map {
            try renderer.render(configuration: configuration, sessionID: 1, frameID: UInt64($0))
        }

        for (index, frame) in frames.enumerated() {
            for retainedFrame in frames[..<index] {
                XCTAssertFalse(frame.pixelBuffer === retainedFrame.pixelBuffer)
            }
        }
    }

    func testRuntimeMuteChangesOnlyCompositionAndPreservesPTSAndPipeline() async throws {
        let service = ManualCameraCaptureService()
        let coordinator = WorkspaceCaptureSessionCoordinator(captureServiceFactory: { service })
        let failures: Set<String> = await withCheckedContinuation { continuation in
            coordinator.synchronizeInputDeviceCaptures(
                inputDevices: [ProgramInputDeviceRecord(
                    name: "Virtual camera",
                    kind: .video,
                    physicalDeviceID: "virtual-camera"
                )],
                availableCameraIDs: ["virtual-camera"],
                canvasWidth: 320,
                canvasHeight: 180,
                frameRate: 60,
                completionHandler: { continuation.resume(returning: $0) }
            )
        }
        XCTAssertEqual(failures, [])
        let firstSample = try XCTUnwrap(service.emitVideo(frameIndex: 7))
        let cameraStep = CompositeProgramStep(
            component: .inputCameraDevice(InputDeviceComponent())
        )
        let composite = CompositeProgramDefinition(steps: [cameraStep])
        let inputKey = composite.inputCameraDeviceMappingKey(for: cameraStep)
        let configuration = ProgramRuntimeConfiguration(
            composite: composite,
            audioChannels: [],
            canvasWidth: 320,
            canvasHeight: 180,
            outputWidth: 320,
            outputHeight: 180,
            frameRate: 60,
            timeSeconds: 0,
            videoPTSMasterCameraID: "virtual-camera",
            cameraIDsByInputKey: [inputKey: "virtual-camera"],
            inputDeviceNamesByInputKey: [inputKey: "Virtual camera"],
            cameraInputColorOverrides: [:],
            backgroundRemovalInputKeys: []
        )
        let renderer = ActiveProgramRenderer(
            captureSessionCoordinator: coordinator,
            lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(interval: .seconds(60))
        )
        renderer.beginSession(1)

        let unmuted = try renderer.render(configuration: configuration, sessionID: 1, frameID: 1)
        renderer.updateProgramPreferences(
            ProgramPreferences(videoMutedByInputDeviceName: ["Virtual%20camera": true])
        )
        let mutedSample = try XCTUnwrap(service.emitVideo(frameIndex: 8))
        let mutedCapturedPixelBuffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(mutedSample))
        let muted = try renderer.render(configuration: configuration, sessionID: 1, frameID: 2)
        let capturedDuringMute = try XCTUnwrap(
            coordinator.latestFrame(forCameraID: "virtual-camera")
        )
        renderer.updateProgramPreferences(ProgramPreferences())
        let finalSample = try XCTUnwrap(service.emitVideo(frameIndex: 9))
        let unmutedAgain = try renderer.render(configuration: configuration, sessionID: 1, frameID: 3)

        XCTAssertEqual(unmuted.presentationTime, firstSample.presentationTimeStamp)
        XCTAssertEqual(muted.presentationTime, mutedSample.presentationTimeStamp)
        XCTAssertEqual(unmutedAgain.presentationTime, finalSample.presentationTimeStamp)
        XCTAssertEqual(unmuted.videoPipelineID, muted.videoPipelineID)
        XCTAssertEqual(muted.videoPipelineID, unmutedAgain.videoPipelineID)
        XCTAssertTrue(capturedDuringMute.pixelBuffer === mutedCapturedPixelBuffer)
        XCTAssertEqual(capturedDuringMute.sourcePresentationTime, mutedSample.presentationTimeStamp)
        XCTAssertEqual(capturedDuringMute.sequenceNumber, 2)
        XCTAssertNotEqual(lumaHash(unmuted.pixelBuffer), lumaHash(muted.pixelBuffer))
        XCTAssertNotEqual(lumaHash(muted.pixelBuffer), lumaHash(unmutedAgain.pixelBuffer))

        renderer.endSession(1)
        await withCheckedContinuation { continuation in
            coordinator.stopAndReset { continuation.resume() }
        }
    }

    func testStopWaitsForInFlightStartAndStopsItAfterCompletion() async {
        let service = DelayedStartCaptureService()
        let coordinator = WorkspaceCaptureSessionCoordinator(captureServiceFactory: { service })
        let startRequested = expectation(description: "start requested")
        service.startRequested = { startRequested.fulfill() }

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
            completionHandler: { _ in }
        )
        await fulfillment(of: [startRequested], timeout: 1)

        let stopped = expectation(description: "fully stopped")
        coordinator.stopAndReset { stopped.fulfill() }
        XCTAssertFalse(coordinator.isFullyStopped())

        service.completeStart()
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertTrue(coordinator.isFullyStopped())
        XCTAssertGreaterThanOrEqual(service.stopCount, 2)
    }

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
        let firstFrameValue = coordinator.latestFrame(forCameraID: "virtual-camera")
        let firstFrame = try XCTUnwrap(firstFrameValue)
        XCTAssertEqual(firstFrame.sourcePresentationTime, CMTime(value: 3, timescale: 60))

        // Advancing the virtual delivery clock models delayed or dropped device
        // frames without sleeping or coupling delivery time to sample PTS.
        XCTAssertEqual(service.advance(toNanoseconds: 149_000_000), 0)
        XCTAssertEqual(service.advance(toNanoseconds: 150_000_000), 1)
        await fulfillment(of: [ticks.expect(2)], timeout: 1)
        let secondFrameValue = coordinator.latestFrame(forCameraID: "virtual-camera")
        let secondFrame = try XCTUnwrap(secondFrameValue)
        XCTAssertEqual(secondFrame.sourcePresentationTime, CMTime(value: 9, timescale: 60))
        XCTAssertEqual(
            secondFrame.sourcePresentationTime - firstFrame.sourcePresentationTime,
            CMTime(value: 6, timescale: 60)
        )

        coordinator.removeTickHandler(tickObserverID)
        await withCheckedContinuation { continuation in
            coordinator.stopAndReset {
                continuation.resume()
            }
        }
    }

    func testCoordinatorDoesNotContinueVideoTimelineAcrossCaptureRestart() async throws {
        let service = ManualCameraCaptureService()
        let coordinator = WorkspaceCaptureSessionCoordinator(captureServiceFactory: { service })
        let inputDevices = [
            ProgramInputDeviceRecord(
                name: "Virtual camera",
                kind: .video,
                physicalDeviceID: "virtual-camera"
            )
        ]

        let initialFailures: Set<String> = await withCheckedContinuation { continuation in
            coordinator.synchronizeInputDeviceCaptures(
                inputDevices: inputDevices,
                availableCameraIDs: ["virtual-camera"],
                canvasWidth: 320,
                canvasHeight: 180,
                frameRate: 60,
                completionHandler: { continuation.resume(returning: $0) }
            )
        }
        XCTAssertEqual(initialFailures, [])
        XCTAssertNotNil(try service.emitVideo(frameIndex: 120))
        let frameBeforeRestart = try XCTUnwrap(
            coordinator.latestFrame(forCameraID: "virtual-camera")
        )

        let restartFailures: Set<String> = await withCheckedContinuation { continuation in
            coordinator.restartAllCaptureSessions {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(restartFailures, [])
        XCTAssertNil(coordinator.latestFrame(forCameraID: "virtual-camera"))
        XCTAssertNotNil(try service.emitVideo(frameIndex: 1))
        let frameAfterRestart = try XCTUnwrap(
            coordinator.latestFrame(forCameraID: "virtual-camera")
        )

        XCTAssertNotEqual(frameBeforeRestart.captureSessionID, frameAfterRestart.captureSessionID)
        XCTAssertEqual(frameAfterRestart.sequenceNumber, 1)
        XCTAssertEqual(frameAfterRestart.sourcePresentationTime, CMTime(value: 1, timescale: 60))

        await withCheckedContinuation { continuation in
            coordinator.stopAndReset { continuation.resume() }
        }
    }
}

private func lumaHash(_ pixelBuffer: CVPixelBuffer) -> UInt64 {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }
    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for row in 0..<height {
        for column in 0..<CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) {
            hash ^= UInt64(bytes[row * bytesPerRow + column])
            hash &*= 0x0000_0100_0000_01b3
        }
    }
    return hash
}

private final class DelayedStartCaptureService: CameraCaptureStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var startCompletion: (@Sendable (Result<Void, any Error>) -> Void)?
    private var recordedStopCount = 0
    var startRequested: (@Sendable () -> Void)?

    var stopCount: Int { lock.withLock { recordedStopCount } }

    func startCameraCapture(
        cameraID _: String,
        audioDeviceID _: String?,
        targetWidth _: Int,
        targetHeight _: Int,
        frameRate _: Int,
        capturesAudio _: Bool,
        failureHandler _: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
        configurationHandler _: (@Sendable (String) -> Void)?,
        handler _: @escaping @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void,
        completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        lock.withLock { startCompletion = completionHandler }
        startRequested?()
    }

    func stop(completionHandler: @escaping @Sendable () -> Void) {
        lock.withLock { recordedStopCount += 1 }
        completionHandler()
    }

    func completeStart() {
        let completion = lock.withLock { () -> (@Sendable (Result<Void, any Error>) -> Void)? in
            defer { startCompletion = nil }
            return startCompletion
        }
        completion?(.success(()))
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
