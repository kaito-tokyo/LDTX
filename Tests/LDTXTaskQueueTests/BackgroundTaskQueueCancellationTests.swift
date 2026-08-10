// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXTaskQueue
import Testing

struct BackgroundTaskQueueCancellationTests {
  @Test func acceptsOnePendingPeriodicTaskPerKey() {
    let queue = BackgroundTaskQueue(label: "test.background.periodic")
    let runningStarted = DispatchSemaphore(value: 0)
    let releaseRunning = DispatchSemaphore(value: 0)

    #expect(
      queue.submit(key: .init("first"), source: .periodic) { finish in
        { _ in
          runningStarted.signal()
          releaseRunning.wait()
          finish()
        }
      })
    #expect(runningStarted.wait(timeout: .now() + 1) == .success)
    #expect(
      queue.submit(key: .init("second"), source: .periodic) { finish in
        { _ in finish() }
      })
    #expect(
      !queue.submit(key: .init("second"), source: .periodic) { finish in
        { _ in finish() }
      })
    releaseRunning.signal()
  }

  @Test func stopCancelsRunningAndDiscardsPendingTasks() async {
    let queue = BackgroundTaskQueue(label: "test.background.stop")
    let runningStarted = TaskQueueAsyncSignal()
    let pendingStarted = TaskQueueAsyncSignal()

    #expect(
      queue.submit(key: .init("running"), source: .manual) { finish in
        { stopToken in
          runningStarted.signal()
          while !stopToken.isStopRequested {
            Thread.sleep(forTimeInterval: 0.001)
          }
          finish()
        }
      })
    #expect(
      queue.submit(key: .init("pending"), source: .manual) { finish in
        { _ in
          pendingStarted.signal()
          finish()
        }
      })
    await runningStarted.wait()

    await withCheckedContinuation { continuation in
      queue.stop { continuation.resume() }
    }

    #expect(queue.stopToken.isStopRequested)
    #expect(!pendingStarted.isSignaled)
  }

  @Test func rejectsSubmissionBeforeStopReturns() async {
    let queue = BackgroundTaskQueue(label: "test.background.stop-rejects")

    queue.stop()

    #expect(
      !queue.submit(key: .init("late"), source: .manual) { finish in
        { _ in finish() }
      })
    await withCheckedContinuation { continuation in
      queue.stop { continuation.resume() }
    }
  }
}
