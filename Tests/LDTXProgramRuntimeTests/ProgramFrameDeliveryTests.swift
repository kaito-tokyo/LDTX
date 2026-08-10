// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Foundation
import Testing

@testable import LDTXProgramRuntime

struct ProgramFrameDeliveryTests {
  @Test func sharedExecutorGivesEachMailboxAQueueTurn() async throws {
    let firstDeliveryStarted = DispatchSemaphore(value: 0)
    let releaseFirstDelivery = DispatchSemaphore(value: 0)
    let deliveredLock = NSLock()
    var delivered: [String] = []
    let executor = ProgramFrameDeliveryExecutor(label: "ProgramFrameDeliveryTests.fairness")
    let firstMailbox = ProgramFrameMailbox(executor: executor) { frame in
      deliveredLock.withLock { delivered.append("first-\(frame.frameID)") }
      if frame.frameID == 1 {
        firstDeliveryStarted.signal()
        releaseFirstDelivery.wait()
      }
    }
    let secondMailbox = ProgramFrameMailbox(executor: executor) { frame in
      deliveredLock.withLock { delivered.append("second-\(frame.frameID)") }
    }

    firstMailbox.submit(try frame(id: 1))
    #expect(
      await Task.detached {
        waitForFrameSemaphore(firstDeliveryStarted, timeout: .now() + 1)
      }.value == .success)
    firstMailbox.submit(try frame(id: 2))
    secondMailbox.submit(try frame(id: 1))
    releaseFirstDelivery.signal()
    await firstMailbox.drain()
    await secondMailbox.drain()
    firstMailbox.close()
    secondMailbox.close()

    #expect(deliveredLock.withLock { delivered } == ["first-1", "second-1", "first-2"])
  }

  @Test func discardedSubscriptionCancelsAndReleasesHandlerCapture() {
    let runtime = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(interval: .seconds(60))
    )
    weak var weakCapture: ProgramFrameHandlerCapture?

    do {
      let capture = ProgramFrameHandlerCapture()
      weakCapture = capture
      runtime.subscribeFrames(replayLatestFrame: false) { [capture] _ in
        capture.consume()
      }
    }

    #expect(weakCapture == nil)
  }

  @Test func concurrentSubscriptionCancellationIsIdempotent() async {
    let runtime = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(interval: .seconds(60))
    )
    let subscription = runtime.subscribeFrames(replayLatestFrame: false) { _ in }

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<32 {
        group.addTask { subscription.cancel() }
      }
    }
    await subscription.cancelAndDrain()
  }

  @Test func cancellationClosesMailboxAfterRuntimeIsReleased() async throws {
    let executor = ProgramFrameDeliveryExecutor(
      label: "ProgramFrameDeliveryTests.released-runtime")
    let blockerStarted = DispatchSemaphore(value: 0)
    let releaseBlocker = DispatchSemaphore(value: 0)
    executor.queue.async {
      blockerStarted.signal()
      releaseBlocker.wait()
    }
    #expect(
      await Task.detached {
        waitForFrameSemaphore(blockerStarted, timeout: .now() + 1)
      }.value == .success)

    let mailbox = ProgramFrameMailbox(executor: executor) { _ in
      Issue.record("Cancelled mailbox unexpectedly delivered a queued frame")
    }
    var runtime: ProgramRuntime? = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(interval: .seconds(60))
    )
    let subscription = ProgramFrameSubscription(
      id: UUID(), mailbox: mailbox, runtime: runtime!)
    mailbox.submit(try frame(id: 1))
    runtime = nil

    subscription.cancel()
    releaseBlocker.signal()
    await subscription.cancelAndDrain()
  }

  @Test func slowConsumerCoalescesPendingFramesToLatest() async throws {
    let firstDeliveryStarted = DispatchSemaphore(value: 0)
    let releaseFirstDelivery = DispatchSemaphore(value: 0)
    let deliveredLock = NSLock()
    var deliveredFrameIDs: [UInt64] = []
    let mailbox = ProgramFrameMailbox(
      executor: ProgramFrameDeliveryExecutor(label: "ProgramFrameDeliveryTests.latest")
    ) { frame in
      deliveredLock.withLock { deliveredFrameIDs.append(frame.frameID) }
      if frame.frameID == 1 {
        firstDeliveryStarted.signal()
        releaseFirstDelivery.wait()
      }
    }

    mailbox.submit(try frame(id: 1))
    #expect(
      await Task.detached {
        waitForFrameSemaphore(firstDeliveryStarted, timeout: .now() + 1)
      }.value == .success)
    mailbox.submit(try frame(id: 2))
    mailbox.submit(try frame(id: 3))
    releaseFirstDelivery.signal()
    await mailbox.drain()
    mailbox.close()

    #expect(deliveredLock.withLock { deliveredFrameIDs } == [1, 3])
  }

  @Test func closeDropsPendingFrameAndDrainWaitsForInFlightDelivery() async throws {
    let deliveryStarted = DispatchSemaphore(value: 0)
    let releaseDelivery = DispatchSemaphore(value: 0)
    let deliveryFinished = DispatchSemaphore(value: 0)
    let mailbox = ProgramFrameMailbox(
      executor: ProgramFrameDeliveryExecutor(label: "ProgramFrameDeliveryTests.drain")
    ) { frame in
      guard frame.frameID == 1 else { return }
      deliveryStarted.signal()
      releaseDelivery.wait()
      deliveryFinished.signal()
    }

    mailbox.submit(try frame(id: 1))
    #expect(
      await Task.detached {
        waitForFrameSemaphore(deliveryStarted, timeout: .now() + 1)
      }.value == .success)
    mailbox.submit(try frame(id: 2))
    mailbox.close()
    let drain = Task { await mailbox.drain() }
    #expect(
      await Task.detached {
        waitForFrameSemaphore(deliveryFinished, timeout: .now() + 0.02)
      }.value == .timedOut)
    releaseDelivery.signal()
    await drain.value
    #expect(
      await Task.detached {
        waitForFrameSemaphore(deliveryFinished, timeout: .now() + 1)
      }.value == .success)
  }

  private func frame(id: UInt64) throws -> ProgramFrame {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      2,
      2,
      kCVPixelFormatType_32BGRA,
      nil,
      &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
      throw ProgramFrameDeliveryTestError.pixelBufferCreationFailed(status)
    }
    return ProgramFrame(frameID: id, pixelBuffer: pixelBuffer, presentationTime: nil)
  }
}

private final class ProgramFrameHandlerCapture: @unchecked Sendable {
  func consume() {}
}

private func waitForFrameSemaphore(
  _ semaphore: DispatchSemaphore,
  timeout: DispatchTime
) -> DispatchTimeoutResult {
  semaphore.wait(timeout: timeout)
}

private enum ProgramFrameDeliveryTestError: Error {
  case pixelBufferCreationFailed(CVReturn)
}
