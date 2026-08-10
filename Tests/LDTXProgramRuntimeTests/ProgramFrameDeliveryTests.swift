// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Foundation
import Testing

@testable import LDTXProgramRuntime

struct ProgramFrameDeliveryTests {
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

private func waitForFrameSemaphore(
  _ semaphore: DispatchSemaphore,
  timeout: DispatchTime
) -> DispatchTimeoutResult {
  semaphore.wait(timeout: timeout)
}

private enum ProgramFrameDeliveryTestError: Error {
  case pixelBufferCreationFailed(CVReturn)
}
