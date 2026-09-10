// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import LDTXCapture
import LDTXProgram
import LDTXProgramRendering
import Testing

@testable import LDTXProgramRuntime

@Suite(.serialized)
struct ManualCapturePipelineSystemTestSuite {
  @Test func runtimeFailureInvalidatesFrameAndRestartsCapture() async throws {
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
    assertEqual(failures, [])
    _ = try unwrap(service.emitVideo(frameIndex: 1))
    assertNotNil(coordinator.latestFrame(forCameraID: "virtual-camera"))

    service.emitRuntimeFailure(.deviceDisconnected(deviceID: "virtual-camera"))

    assertNil(coordinator.latestFrame(forCameraID: "virtual-camera"))
    for _ in 0..<100 where service.startCount < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    assertEqual(service.startCount, 2)
    assertNotNil(service.request)
    assertEqual(coordinator.reconnectAttemptForTesting(cameraID: "virtual-camera"), 1)
    _ = try unwrap(service.emitVideo(frameIndex: 2))
    assertNotNil(coordinator.latestFrame(forCameraID: "virtual-camera"))
    assertEqual(coordinator.reconnectAttemptForTesting(cameraID: "virtual-camera"), 0)
    await withCheckedContinuation { continuation in
      coordinator.stopAndReset { continuation.resume() }
    }
  }

  @Test func explicitRestartCancelsPendingDelayedReconnect() async throws {
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
    assertEqual(failures, [])

    service.emitRuntimeFailure(.deviceDisconnected(deviceID: "virtual-camera"))
    for _ in 0..<100 where service.startCount < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    assertEqual(service.startCount, 2)
    service.emitRuntimeFailure(.deviceDisconnected(deviceID: "virtual-camera"))

    let restartFailures: Set<String> = await withCheckedContinuation { continuation in
      coordinator.restartAllCaptureSessions { continuation.resume(returning: $0) }
    }
    assertEqual(restartFailures, [])
    assertEqual(service.startCount, 3)
    try await Task.sleep(for: .milliseconds(400))
    assertEqual(service.startCount, 3)

    await withCheckedContinuation { continuation in
      coordinator.stopAndReset { continuation.resume() }
    }
  }

  @Test func acceptedFrameCancelsPendingDelayedReconnect() async throws {
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
    assertEqual(failures, [])

    service.emitRuntimeFailure(.deviceDisconnected(deviceID: "virtual-camera"))
    for _ in 0..<100 where service.startCount < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    assertEqual(service.startCount, 2)

    service.emitRuntimeFailure(.deviceDisconnected(deviceID: "virtual-camera"))
    assertNotNil(try service.emitVideo(frameIndex: 1))
    try await Task.sleep(for: .milliseconds(400))
    assertEqual(service.startCount, 2)

    await withCheckedContinuation { continuation in
      coordinator.stopAndReset { continuation.resume() }
    }
  }

  @Test func rendererDoesNotReuseOutputBuffersRetainedByConsumers() throws {
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
        assertFalse(frame.pixelBuffer === retainedFrame.pixelBuffer)
      }
    }
  }

  @Test func runtimeMuteChangesOnlyCompositionAndPreservesPTSAndPipeline() async throws {
    let service = ManualCameraCaptureService()
    let coordinator = WorkspaceCaptureSessionCoordinator(captureServiceFactory: { service })
    let failures: Set<String> = await withCheckedContinuation { continuation in
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
        completionHandler: { continuation.resume(returning: $0) }
      )
    }
    assertEqual(failures, [])
    let firstSample = try unwrap(service.emitVideo(frameIndex: 7))
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
    let mutedSample = try unwrap(service.emitVideo(frameIndex: 8))
    let mutedCapturedPixelBuffer = try unwrap(CMSampleBufferGetImageBuffer(mutedSample))
    let muted = try renderer.render(configuration: configuration, sessionID: 1, frameID: 2)
    let capturedDuringMute = try unwrap(
      coordinator.latestFrame(forCameraID: "virtual-camera")
    )
    renderer.updateProgramPreferences(ProgramPreferences())
    let finalSample = try unwrap(service.emitVideo(frameIndex: 9))
    let unmutedAgain = try renderer.render(configuration: configuration, sessionID: 1, frameID: 3)

    assertEqual(unmuted.presentationTime, firstSample.presentationTimeStamp)
    assertEqual(muted.presentationTime, mutedSample.presentationTimeStamp)
    assertEqual(unmutedAgain.presentationTime, finalSample.presentationTimeStamp)
    assertEqual(unmuted.videoPipelineID, muted.videoPipelineID)
    assertEqual(muted.videoPipelineID, unmutedAgain.videoPipelineID)
    assertTrue(capturedDuringMute.pixelBuffer === mutedCapturedPixelBuffer)
    assertEqual(capturedDuringMute.sourcePresentationTime, mutedSample.presentationTimeStamp)
    assertEqual(capturedDuringMute.sequenceNumber, 2)
    assertNotEqual(lumaHash(unmuted.pixelBuffer), lumaHash(muted.pixelBuffer))
    assertNotEqual(lumaHash(muted.pixelBuffer), lumaHash(unmutedAgain.pixelBuffer))

    renderer.endSession(1)
    await withCheckedContinuation { continuation in
      coordinator.stopAndReset { continuation.resume() }
    }
  }

  @Test func stopWaitsForInFlightStartAndStopsItAfterCompletion() async {
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
    assertFalse(coordinator.isFullyStopped())

    service.completeStart()
    await fulfillment(of: [stopped], timeout: 1)
    assertTrue(coordinator.isFullyStopped())
    assertGreaterThanOrEqual(service.stopCount, 2)
  }

  @Test func manualDeviceDoesNotProduceFramesUntilExplicitlyDriven() async throws {
    let service = ManualCameraCaptureService()
    let recorder = SampleRecorder()

    try await withCheckedThrowingContinuation { continuation in
      service.startCameraCapture(
        cameraID: "virtual-camera",
        targetWidth: 320,
        targetHeight: 180,
        frameRate: 60,
        configurationHandler: nil,
        handler: { sampleBuffer, kind in
          recorder.append(sampleBuffer, kind: kind)
        },
        completionHandler: { result in
          continuation.resume(with: result)
        }
      )
    }

    assertEqual(recorder.count, 0)
    assertEqual(
      service.request,
      ManualCameraCaptureService.Request(
        cameraID: "virtual-camera",
        targetWidth: 320,
        targetHeight: 180,
        frameRate: 60,
      )
    )

    let sampleBuffer = try unwrap(service.emitVideo(frameIndex: 7))

    assertEqual(recorder.count, 1)
    assertEqual(recorder.kinds, [.video])
    assertEqual(
      sampleBuffer.presentationTimeStamp,
      CMTime(value: 7, timescale: 60)
    )

    assertNotNil(try service.scheduleVideo(frameIndex: 8, atNanoseconds: 25_000_000))
    assertNotNil(try service.scheduleVideo(frameIndex: 9, atNanoseconds: 25_000_000))
    assertEqual(service.advance(toNanoseconds: 24_999_999), 0)
    assertEqual(recorder.count, 1)
    assertEqual(service.advance(toNanoseconds: 25_000_000), 2)
    assertEqual(
      recorder.presentationTimes,
      [
        CMTime(value: 7, timescale: 60),
        CMTime(value: 8, timescale: 60),
        CMTime(value: 9, timescale: 60),
      ]
    )

    service.stop()
    assertNil(service.request)
    assertNil(try service.emitVideo(frameIndex: 8))
    assertEqual(recorder.count, 3)
  }

  @Test func coordinatorUsesPTSFromManuallyDeliveredDeviceFrames() async throws {
    let service = ManualCameraCaptureService()
    let coordinator = WorkspaceCaptureSessionCoordinator(
      captureServiceFactory: { service }
    )
    let ticks = TickRecorder()
    let tickObserverID = coordinator.addTickHandler { tick in
      ticks.append(tick)
    }
    assertEqual(ticks.values, [0])

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
    assertEqual(failedCameraIDs, [])

    assertNotNil(try service.scheduleVideo(frameIndex: 3, atNanoseconds: 50_000_000))
    assertNotNil(try service.scheduleVideo(frameIndex: 9, atNanoseconds: 150_000_000))
    assertEqual(service.advance(toNanoseconds: 49_000_000), 0)
    assertEqual(service.advance(toNanoseconds: 50_000_000), 1)
    await fulfillment(of: [ticks.expect(1)], timeout: 1)
    let firstFrameValue = coordinator.latestFrame(forCameraID: "virtual-camera")
    let firstFrame = try unwrap(firstFrameValue)
    assertEqual(firstFrame.sourcePresentationTime, CMTime(value: 3, timescale: 60))

    // Advancing the virtual delivery clock models delayed or dropped device
    // frames without sleeping or coupling delivery time to sample PTS.
    assertEqual(service.advance(toNanoseconds: 149_000_000), 0)
    assertEqual(service.advance(toNanoseconds: 150_000_000), 1)
    await fulfillment(of: [ticks.expect(2)], timeout: 1)
    let secondFrameValue = coordinator.latestFrame(forCameraID: "virtual-camera")
    let secondFrame = try unwrap(secondFrameValue)
    assertEqual(secondFrame.sourcePresentationTime, CMTime(value: 9, timescale: 60))
    assertEqual(
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

  @Test func coordinatorDoesNotContinueVideoTimelineAcrossCaptureRestart() async throws {
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
    assertEqual(initialFailures, [])
    assertNotNil(try service.emitVideo(frameIndex: 120))
    let frameBeforeRestart = try unwrap(
      coordinator.latestFrame(forCameraID: "virtual-camera")
    )

    let restartFailures: Set<String> = await withCheckedContinuation { continuation in
      coordinator.restartAllCaptureSessions {
        continuation.resume(returning: $0)
      }
    }
    assertEqual(restartFailures, [])
    assertNil(coordinator.latestFrame(forCameraID: "virtual-camera"))
    assertNotNil(try service.emitVideo(frameIndex: 1))
    let frameAfterRestart = try unwrap(
      coordinator.latestFrame(forCameraID: "virtual-camera")
    )

    assertNotEqual(frameBeforeRestart.captureSessionID, frameAfterRestart.captureSessionID)
    assertEqual(frameAfterRestart.sequenceNumber, 1)
    assertEqual(frameAfterRestart.sourcePresentationTime, CMTime(value: 1, timescale: 60))

    await withCheckedContinuation { continuation in
      coordinator.stopAndReset { continuation.resume() }
    }
  }

  private func expectation(description: String) -> TestExpectation {
    TestExpectation(description: description)
  }

  private func fulfillment(of expectations: [TestExpectation], timeout: TimeInterval) async {
    let deadline = DispatchTime.now() + timeout
    for expectation in expectations {
      let fulfilled = await Task.detached { expectation.wait(until: deadline) }.value
      if !fulfilled {
        Issue.record(TestFailure("Timed out waiting for \(expectation.description)"))
      }
    }
  }
}

private final class TestExpectation: @unchecked Sendable {
  let description: String
  private let semaphore = DispatchSemaphore(value: 0)

  init(description: String) { self.description = description }
  func fulfill() { semaphore.signal() }
  func wait(until deadline: DispatchTime) -> Bool { semaphore.wait(timeout: deadline) == .success }
}

private struct TestFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

private func assertEqual<Value: Equatable>(_ actual: Value, _ expected: Value) {
  if actual != expected { Issue.record(TestFailure("Expected \(expected), got \(actual)")) }
}

private func assertNotEqual<Value: Equatable>(_ actual: Value, _ expected: Value) {
  if actual == expected { Issue.record(TestFailure("Values unexpectedly equal: \(actual)")) }
}

private func assertTrue(_ value: Bool) {
  if !value { Issue.record(TestFailure("Expected true")) }
}

private func assertFalse(_ value: Bool) {
  if value { Issue.record(TestFailure("Expected false")) }
}

private func assertGreaterThanOrEqual<Value: Comparable>(_ actual: Value, _ expected: Value) {
  if actual < expected {
    Issue.record(TestFailure("Expected \(actual) to be at least \(expected)"))
  }
}

private func assertNil<Value>(_ value: Value?) {
  if value != nil { Issue.record(TestFailure("Expected nil")) }
}

private func assertNotNil<Value>(_ value: Value?) {
  if value == nil { Issue.record(TestFailure("Expected non-nil value")) }
}

private func unwrap<Value>(_ value: Value?) throws -> Value { try #require(value) }

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
    targetWidth _: Int,
    targetHeight _: Int,
    frameRate _: Int,
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
  private var expectationsByValue: [UInt64: [TestExpectation]] = [:]

  var values: [UInt64] {
    lock.withLock { recordedValues }
  }

  func append(_ value: UInt64) {
    let expectations = lock.withLock { () -> [TestExpectation] in
      recordedValues.append(value)
      return expectationsByValue.removeValue(forKey: value) ?? []
    }
    for expectation in expectations {
      expectation.fulfill()
    }
  }

  func expect(_ value: UInt64) -> TestExpectation {
    let expectation = TestExpectation(description: "tick \(value)")
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
