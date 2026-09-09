// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreMedia
import Foundation
import LDTXCapture
import Testing

@testable import LDTXProgramRuntime

extension LDTXIntegrationEasyTests {
  @Suite
  struct WorkspaceCaptureSessionCoordinatorEasyTests {
    @Test func runtimeFailedAudioCaptureRetainsUnsubscribeFenceUntilCopiedCallbackFinishes()
      async throws
    {
      let capture = IntegrationDelayedAudioCaptureService()
      let coordinator = WorkspaceCaptureSessionCoordinator(
        captureServiceFactory: { ManualCameraCaptureService() },
        audioCaptureServiceFactory: { capture })
      let started = IntegrationTestExpectation(description: "capture started")
      let handlerEntered = IntegrationTestExpectation(description: "copied handler entered")
      let unsubscribeCompletion = IntegrationCallbackSpy()
      let releaseHandler = DispatchSemaphore(value: 0)
      let subscription = coordinator.subscribeAudio(
        deviceID: "device",
        failureHandler: { _ in },
        sampleHandler: { _ in
          handlerEntered.fulfill()
          releaseHandler.wait()
        },
        completionHandler: { _ in started.fulfill() })
      capture.completeStart()
      await fulfillment(of: [started], timeout: 1)

      DispatchQueue.global().async {
        capture.emit(try? makeIntegrationEmptySampleBuffer())
      }
      await fulfillment(of: [handlerEntered], timeout: 1)

      var previousFormat = AudioStreamBasicDescription()
      previousFormat.mSampleRate = 44_100
      var currentFormat = AudioStreamBasicDescription()
      currentFormat.mSampleRate = 48_000
      capture.emitRuntimeFailure(
        .audioFormatChanged(
          deviceID: "device", previous: previousFormat, current: currentFormat))
      coordinator.unsubscribeAudio(subscription) { unsubscribeCompletion.receive() }
      #expect(unsubscribeCompletion.count == 0)

      // A stale callback must not complete the fence belonging to the accepted
      // callback that is still blocked above. The retired capture stays alive
      // through that callback, so this exercises rejection rather than weak-self
      // expiration.
      capture.emit(try makeIntegrationEmptySampleBuffer())
      #expect(unsubscribeCompletion.count == 0)

      releaseHandler.signal()
      #expect(await waitUntil { unsubscribeCompletion.count == 1 })
    }

    private func fulfillment(of expectations: [IntegrationTestExpectation], timeout: TimeInterval)
      async
    {
      let deadline = DispatchTime.now() + timeout
      for expectation in expectations {
        #expect(await Task.detached { expectation.wait(until: deadline) }.value)
      }
    }

    private func waitUntil(
      timeout: TimeInterval = 1,
      _ condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
      }
      return condition()
    }
  }
}

private final class IntegrationTestExpectation: @unchecked Sendable {
  let description: String
  private let semaphore = DispatchSemaphore(value: 0)

  init(description: String) { self.description = description }

  func fulfill() { semaphore.signal() }

  func wait(until deadline: DispatchTime) -> Bool {
    semaphore.wait(timeout: deadline) == .success
  }
}

private final class IntegrationCallbackSpy: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0

  var count: Int { lock.withLock { storedCount } }

  func receive() { lock.withLock { storedCount += 1 } }
}

private func makeIntegrationEmptySampleBuffer() throws -> CMSampleBuffer {
  var sampleBuffer: CMSampleBuffer?
  let status = CMSampleBufferCreate(
    allocator: kCFAllocatorDefault,
    dataBuffer: nil,
    dataReady: true,
    makeDataReadyCallback: nil,
    refcon: nil,
    formatDescription: nil,
    sampleCount: 0,
    sampleTimingEntryCount: 0,
    sampleTimingArray: nil,
    sampleSizeEntryCount: 0,
    sampleSizeArray: nil,
    sampleBufferOut: &sampleBuffer)
  #expect(status == noErr)
  return try #require(sampleBuffer)
}

private final class IntegrationDelayedAudioCaptureService: ProgramAudioCaptureStreaming,
  @unchecked Sendable
{
  private struct State {
    var completion: (@Sendable (Result<Void, any Error>) -> Void)?
    var failureHandler: (@Sendable (CaptureSessionRuntimeFailure) -> Void)?
    var sampleHandler: (@Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void)?
  }

  private let lock = NSLock()
  private var state = State()

  func startAudioCapture(
    audioDeviceID _: String?,
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    handler: @escaping @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    lock.withLock {
      state.completion = completionHandler
      state.failureHandler = failureHandler
      state.sampleHandler = handler
    }
  }

  func completeStart() {
    let completion = lock.withLock { () -> (@Sendable (Result<Void, any Error>) -> Void)? in
      let completion = state.completion
      state.completion = nil
      return completion
    }
    completion?(.success(()))
  }

  func emitRuntimeFailure(_ failure: CaptureSessionRuntimeFailure) {
    lock.withLock { state.failureHandler }?(failure)
  }

  func emit(_ sampleBuffer: CMSampleBuffer?) {
    guard let sampleBuffer else { return }
    lock.withLock { state.sampleHandler }?(sampleBuffer, .audio)
  }

  func stop(completionHandler: @escaping @Sendable () -> Void) { completionHandler() }
}
