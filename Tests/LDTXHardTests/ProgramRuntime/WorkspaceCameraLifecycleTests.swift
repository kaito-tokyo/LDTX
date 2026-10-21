// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreVideo
import Foundation
@testable import LDTXCapture
@testable import LDTXProgramRuntime
import Testing

@Suite struct WorkspaceCameraLifecycleIntegrationTestSuite {
  @Test func stopDuringStartWaitsForPhysicalStopAndRepeatedCloseJoinsBarrier() async throws {
    let manager = ControlledCameraManager(delayStart: true, delayStop: true)
    let workspace = workspace(manager)
    synchronize(workspace, ["A"])
    try await eventually { manager.startCount == 1 }
    let closed = Counter()
    workspace.stopAndReset { closed.increment() }
    workspace.stopAndReset { closed.increment() }
    #expect(closed.value == 0)
    manager.completeStart(.success(()))
    try await eventually { manager.stopCount == 1 }
    #expect(closed.value == 0)
    manager.completeStop()
    // Coordinator fences the in-flight start with an additional idempotent stop.
    try await eventually { manager.stopCount == 2 }
    manager.completeStop()
    try await eventually { closed.value == 2 }
    #expect(workspace.isFullyStopped())
    #expect(!manager.active)
    #expect(manager.startCount == 1)
  }

  @Test func twoCameraStopsCannotApplyStalePlanAfterOtherStopCompletes() async throws {
    let a = ControlledCameraManager(delayStop: true)
    let b = ControlledCameraManager()
    let factory = CameraFactory([a, b])
    let workspace = factory.workspace()
    synchronize(workspace, ["A"])
    try await eventually { a.active }
    synchronize(workspace, ["A", "B"])
    try await eventually { b.active }
    let closed = Counter()
    workspace.stopAndReset { closed.increment() }
    try await eventually { a.stopCount == 1 && !b.active }
    #expect(closed.value == 0)
    a.completeStop()
    try await eventually { closed.value == 1 }
    #expect(workspace.isFullyStopped())
    #expect(!a.active && !b.active)
    #expect(a.startCount == 1 && b.startCount == 1)
  }

  @Test func oldFailedStartCannotRollbackNewCameraOrAnotherWorkspace() async throws {
    let a = ControlledCameraManager(delayStart: true)
    let b = ControlledCameraManager()
    let other = ControlledCameraManager()
    let workspace = CameraFactory([a, b]).workspace()
    let anotherWorkspace = self.workspace(other)
    let failedStart = Counter()
    synchronize(workspace, ["A"], completion: { _ in failedStart.increment() })
    try await eventually { a.startCount == 1 }
    synchronize(workspace, ["A", "B"])
    synchronize(anotherWorkspace, ["A"])
    try await eventually { b.active && other.active }
    a.completeStart(.failure(CaptureSessionManagerError.cannotAddInput("A")))
    try await eventually { failedStart.value == 1 }
    synchronize(workspace, ["B"])
    #expect(b.active && other.active)
    #expect(b.startCount == 1 && other.startCount == 1)
    await close(workspace)
    #expect(other.active)
    await close(anotherWorkspace)
  }

  @Test func sameCameraIsSharedWithinWorkspaceButNotAcrossWorkspaces() async throws {
    let a = ControlledCameraManager()
    let b = ControlledCameraManager()
    let first = workspace(a)
    let second = workspace(b)
    synchronize(first, ["same"])
    try await eventually { a.active }
    // A different canvas/fps must neither restart nor reconfigure this camera.
    synchronize(first, ["same"], width: 1920, frameRate: 60)
    synchronize(second, ["same"])
    try await eventually { b.active }
    #expect(a.startCount == 1 && b.startCount == 1)
    await close(first)
    #expect(!a.active && b.active)
    await close(second)
  }

  @Test func lateSamplesAndFailuresAfterCloseCannotRestartOrPublish() async throws {
    let manager = ControlledCameraManager()
    let workspace = workspace(manager)
    synchronize(workspace, ["A"])
    try await eventually { manager.active }
    let sample = try sampleBuffer()
    manager.emitCopied(sample)
    #expect(workspace.latestFrame(forCameraID: "A") != nil)
    await close(workspace)
    manager.emitCopied(sample)
    manager.emitCopiedFailure()
    // A FIFO fence on the reconnect executor is not exposed; absence of an
    // owned capture plus the synchronous failure callback proves rejection.
    #expect(workspace.latestFrame(forCameraID: "A") == nil)
    #expect(workspace.reconnectAttemptForTesting(cameraID: "A") == nil)
    #expect(manager.startCount == 1)
    #expect(workspace.isFullyStopped())
  }

  @Test func callbacksFromEarlierSessionCannotContaminateReplacementSession() async throws {
    let manager = ControlledCameraManager()
    let workspace = workspace(manager)
    synchronize(workspace, ["A"])
    try await eventually { manager.active }
    let oldSample = manager.sampleCallback
    let oldFailure = manager.failureCallback
    await withCheckedContinuation { continuation in
      workspace.restartAllCaptureSessions { _ in continuation.resume() }
    }
    #expect(manager.startCount == 2)
    let sample = try sampleBuffer()
    oldSample?(CapturedSample(sourceKey: "A", deviceID: "A", kind: .video, sampleBuffer: sample))
    oldFailure?(.deviceDisconnected(deviceID: "A"))
    #expect(workspace.latestFrame(forCameraID: "A") == nil)
    #expect(workspace.reconnectAttemptForTesting(cameraID: "A") == 0)
    manager.emitCopied(sample)
    #expect(workspace.latestFrame(forCameraID: "A") != nil)
    await close(workspace)
  }

  @Test func rejectedRestartDoesNotQueueCleanupBeyondCloseBarrier() async throws {
    let manager = ControlledCameraManager(delayStop: true)
    let workspace = workspace(manager)
    synchronize(workspace, ["A"])
    try await eventually { manager.active }
    let restarted = Counter()
    let closed = Counter()
    workspace.restartAllCaptureSessions { _ in restarted.increment() }
    try await eventually { manager.stopCount == 1 }
    workspace.stopAndReset { closed.increment() }
    manager.completeStop()
    try await eventually { manager.stopCount == 2 && restarted.value == 1 }
    #expect(closed.value == 0)
    manager.completeStop()
    try await eventually { closed.value == 1 }
    #expect(workspace.isFullyStopped())
    #expect(manager.stopCount == 2 && manager.startCount == 1)
    #expect(!manager.active)
  }

  @Test func closeDuringMultiCameraRestartDoesNotStopRetiredRemainderAgain() async throws {
    let a = ControlledCameraManager(delayStop: true)
    let b = ControlledCameraManager(delayStop: true)
    let workspace = CameraFactory([a, b]).workspace()
    synchronize(workspace, ["A"])
    try await eventually { a.active }
    synchronize(workspace, ["A", "B"])
    try await eventually { b.active }
    let restarted = Counter()
    let closed = Counter()
    workspace.restartAllCaptureSessions { _ in restarted.increment() }
    try await eventually { a.stopCount + b.stopCount == 1 }
    let first = a.stopCount == 1 ? a : b
    let other = a.stopCount == 1 ? b : a
    workspace.stopAndReset { closed.increment() }
    try await eventually { other.stopCount == 1 }
    other.completeStop()
    #expect(closed.value == 0)
    first.completeStop()
    try await eventually { first.stopCount == 2 && restarted.value == 1 }
    #expect(closed.value == 0)
    first.completeStop()
    try await eventually { closed.value == 1 }
    #expect(workspace.isFullyStopped())
    #expect(first.stopCount == 2 && other.stopCount == 1)
    #expect(a.startCount == 1 && b.startCount == 1)
  }

  @Test func closeDuringNormalReconnectDrainsStopWithoutRestart() async throws {
    let manager = ControlledCameraManager(delayStop: true)
    let workspace = workspace(manager)
    synchronize(workspace, ["A"])
    try await eventually { manager.active }
    // Exercise the production failure -> reconnect queue, not restartAll.
    manager.emitCopiedFailure()
    try await eventually { manager.stopCount == 1 }
    let closed = Counter()
    workspace.stopAndReset { closed.increment() }
    manager.completeStop()
    try await eventually { manager.stopCount == 2 }
    #expect(closed.value == 0)
    manager.completeStop()
    try await eventually { closed.value == 1 }
    manager.emitCopiedFailure()
    #expect(workspace.isFullyStopped())
    #expect(manager.startCount == 1 && manager.stopCount == 2)
    #expect(workspace.reconnectAttemptForTesting(cameraID: "A") == nil)
  }

  private func workspace(_ manager: ControlledCameraManager) -> WorkspaceCaptureSessionCoordinator {
    CameraFactory([manager]).workspace()
  }
  private func synchronize(
    _ workspace: WorkspaceCaptureSessionCoordinator, _ ids: Set<String>, width: Int = 320,
    frameRate: Int = 30, completion: @escaping @Sendable (Set<String>) -> Void = { _ in }
  ) {
    workspace.synchronizePhysicalInputCaptures(
      videoCameraIDs: ids, audioDeviceIDs: [], availableCameraIDs: ids,
      canvasWidth: width, canvasHeight: 180, frameRate: frameRate, completionHandler: completion)
  }
  private func close(_ workspace: WorkspaceCaptureSessionCoordinator) async {
    await withCheckedContinuation { continuation in workspace.stopAndReset { continuation.resume() }
    }
  }
  private func eventually(_ predicate: () -> Bool) async throws {
    for _ in 0..<1000 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(predicate())
  }
  private func sampleBuffer() throws -> CMSampleBuffer {
    var buffer: CVPixelBuffer?
    try #require(
      CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let pixel = try #require(buffer)
    var description: CMVideoFormatDescription?
    try #require(
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: nil, imageBuffer: pixel, formatDescriptionOut: &description) == noErr)
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: CMTime(value: 7, timescale: 30), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    try #require(
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: nil, imageBuffer: pixel, formatDescription: #require(description),
        sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
  }
}

private final class Counter: @unchecked Sendable {
  let lock = NSLock()
  var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}

private final class CameraFactory: @unchecked Sendable {
  let lock = NSLock()
  var managers: [ControlledCameraManager]
  init(_ managers: [ControlledCameraManager]) { self.managers = managers }
  func workspace() -> WorkspaceCaptureSessionCoordinator {
    WorkspaceCaptureSessionCoordinator(
      captureServiceFactory: { [self] in
        let manager = lock.withLock { managers.removeFirst() }
        return CameraCaptureService(manager: manager)
      }, audioCaptureServiceFactory: { SilentAudioCapture() })
  }
}

private final class SilentAudioCapture: ProgramAudioCaptureStreaming, @unchecked Sendable {
  func startAudioCapture(
    audioDeviceID: String?,
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    handler: @escaping @Sendable (CMSampleBuffer) -> Void,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) { completionHandler(.success(())) }
  func stop(completionHandler: @escaping @Sendable () -> Void) { completionHandler() }
}

private final class ControlledCameraManager: CameraCaptureSessionManaging, @unchecked Sendable {
  private let lock = NSLock()
  private let delayStart: Bool
  private let delayStop: Bool
  private var starts = 0
  private var stops = 0
  private var running = false
  private var startCompletion: (@Sendable (Result<Void, any Error>) -> Void)?
  private var stopCompletion: (@Sendable () -> Void)?
  private var copiedSample: CaptureSessionManager.SampleHandler?
  private var copiedFailure: CaptureSessionManager.FailureHandler?
  var active: Bool { lock.withLock { running } }
  var startCount: Int { lock.withLock { starts } }
  var stopCount: Int { lock.withLock { stops } }
  var sampleCallback: CaptureSessionManager.SampleHandler? { lock.withLock { copiedSample } }
  var failureCallback: CaptureSessionManager.FailureHandler? { lock.withLock { copiedFailure } }
  init(delayStart: Bool = false, delayStop: Bool = false) {
    self.delayStart = delayStart
    self.delayStop = delayStop
  }
  func availableCameras() -> [CameraCaptureSource] { [] }
  func start(
    request: CaptureSessionRequest, handler: @escaping CaptureSessionManager.SampleHandler,
    failureHandler: @escaping CaptureSessionManager.FailureHandler,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    lock.withLock {
      starts += 1
      startCompletion = completionHandler
      copiedSample = handler
      copiedFailure = failureHandler
    }
    if !delayStart { completeStart(.success(())) }
  }
  func stop(completionHandler: @escaping @Sendable () -> Void) {
    lock.withLock {
      stops += 1
      stopCompletion = completionHandler
    }
    if !delayStop { completeStop() }
  }
  func completeStart(_ result: Result<Void, any Error>) {
    let completion = lock.withLock {
      if case .success = result { running = true }
      let callback = startCompletion
      startCompletion = nil
      return callback
    }
    completion?(result)
  }
  func completeStop() {
    let completion = lock.withLock {
      running = false
      let callback = stopCompletion
      stopCompletion = nil
      return callback
    }
    completion?()
  }
  func emitCopied(_ sample: CMSampleBuffer) {
    sampleCallback?(
      CapturedSample(sourceKey: "A", deviceID: "A", kind: .video, sampleBuffer: sample))
  }
  func emitCopiedFailure() { failureCallback?(.deviceDisconnected(deviceID: "A")) }
}
