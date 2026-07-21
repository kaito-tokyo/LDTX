// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXTaskQueue
import Testing

struct SessionTaskQueueTests {
  @Test func executesFireAndForgetTasksSerially() {
    let log = BackgroundQueueTestLog()
    let queue = SessionTaskQueue(label: "test.session.serial")

    #expect(queue.submit(key: SessionTaskKey("first"), source: .normal, task(named: "first", log: log)))
    #expect(
      queue.submit(
        key: SessionTaskKey("second"), source: .normal, task(named: "second", log: log)))
    #expect(log.waitForStarts(1))
    #expect(log.started == ["first"])
    log.completeNext()
    #expect(log.waitForStarts(2))
    #expect(log.started == ["first", "second"])
    log.completeNext()
  }

  @Test func deduplicatesRunningAndPendingKeys() {
    let log = BackgroundQueueTestLog()
    let queue = SessionTaskQueue(label: "test.session.deduplicate")

    #expect(queue.submit(key: SessionTaskKey("vision"), source: .normal, task(named: "first", log: log)))
    #expect(log.waitForStarts(1))
    #expect(
      !queue.submit(
          key: SessionTaskKey("vision"), source: .normal, task(named: "duplicate", log: log)))
    #expect(
      queue.submit(
        key: SessionTaskKey("automation"), source: .normal,
        task(named: "second", log: log)))
    #expect(
      !queue.submit(
        key: SessionTaskKey("automation"), source: .normal,
        task(named: "duplicate-pending", log: log)))
    log.completeNext()
    #expect(log.waitForStarts(2))
    #expect(log.started == ["first", "second"])
    log.completeNext()
  }

  @Test func whenIdleSkipsWhileQueueHasWork() {
    let log = BackgroundQueueTestLog()
    let queue = SessionTaskQueue(label: "test.session.when-idle")

    #expect(
      queue.submit(
        key: SessionTaskKey("manual"), source: .normal, task(named: "manual", log: log)))
    #expect(log.waitForStarts(1))
    #expect(
      !queue.submit(
        key: SessionTaskKey("periodic"),
        source: .whenIdle,
        task(named: "periodic", log: log)
      ))
    log.completeNext()
  }

  @Test func stopSignalsRunningTaskDropsPendingAndNotifiesOnMainActor() async {
    let log = BackgroundQueueTestLog()
    let queue = SessionTaskQueue(label: "test.session.cancel")

    #expect(
      queue.submit(
        key: SessionTaskKey("running"), source: .normal, task(named: "running", log: log)))
    #expect(
      queue.submit(
        key: SessionTaskKey("pending"), source: .normal, task(named: "pending", log: log)))
    #expect(log.waitForStarts(1))

    await withCheckedContinuation { continuation in
      queue.stop {
        MainActor.preconditionIsolated()
        continuation.resume()
      }
      #expect(waitUntil { queue.stopToken.isStopRequested })
      #expect(
        !queue.submit(
          key: SessionTaskKey("rejected"), source: .normal,
          task(named: "rejected", log: log)))
      log.completeNext()
    }

    #expect(log.started == ["running"])
  }

  @Test func completionIsOneShot() {
    let log = BackgroundQueueTestLog()
    let queue = SessionTaskQueue(label: "test.session.oneshot")
    #expect(
      queue.submit(key: SessionTaskKey("first"), source: .normal, task(named: "first", log: log)))
    #expect(
      queue.submit(
        key: SessionTaskKey("second"), source: .normal, task(named: "second", log: log)))
    #expect(log.waitForStarts(1))
    let completion = log.removeNextCompletion()
    completion?()
    completion?()
    #expect(log.waitForStarts(2))
    #expect(log.started == ["first", "second"])
    log.completeNext()
  }

  @Test func finishClosesSubmissionsThenRunsFinalizer() {
    let finalizerStarted = DispatchSemaphore(value: 0)
    let queue = SessionTaskQueue(label: "test.session.finish") { completion in
      { _ in
        finalizerStarted.signal()
        completion()
      }
    }
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let finishCompleted = DispatchSemaphore(value: 0)

    #expect(
      queue.submit(key: SessionTaskKey("first"), source: .normal) { completion in
        { _ in
          firstStarted.signal()
          releaseFirst.wait()
          completion()
        }
      })
    #expect(firstStarted.wait(timeout: .now() + 1) == .success)
    queue.finish { finishCompleted.signal() }
    let laterTask: SessionTaskQueue.TaskFactory = { completion in
      { _ in completion() }
    }
    let acceptedLater = queue.submit(
      key: SessionTaskKey("later"), source: .normal, laterTask)
    #expect(!acceptedLater)
    #expect(finishCompleted.wait(timeout: .now() + 0.01) == .timedOut)
    #expect(finalizerStarted.wait(timeout: .now() + 0.01) == .timedOut)
    releaseFirst.signal()
    #expect(finalizerStarted.wait(timeout: .now() + 1) == .success)
    #expect(finishCompleted.wait(timeout: .now() + 1) == .success)
  }

  private func task(
    named name: String,
    log: BackgroundQueueTestLog
  ) -> SessionTaskQueue.TaskFactory {
    { completion in
      { stopToken in
        log.start(name, stopToken: stopToken, completion: completion)
      }
    }
  }

  private func waitUntil(_ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(1)
    while !predicate(), Date() < deadline {
      Thread.sleep(forTimeInterval: 0.001)
    }
    return predicate()
  }
}

private final class BackgroundQueueTestLog: @unchecked Sendable {
  private let condition = NSCondition()
  private var storedStarted: [String] = []
  private var completions: [@Sendable () -> Void] = []

  var started: [String] { condition.withLock { storedStarted } }

  func start(
    _ name: String,
    stopToken: StopToken,
    completion: @escaping @Sendable () -> Void
  ) {
    condition.withLock {
      storedStarted.append(name)
      completions.append(completion)
      condition.broadcast()
    }
  }

  func waitForStarts(_ count: Int) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(1)
    while storedStarted.count < count {
      if !condition.wait(until: deadline) { return false }
    }
    return true
  }

  func completeNext() {
    removeNextCompletion()?()
  }

  func removeNextCompletion() -> (@Sendable () -> Void)? {
    condition.withLock { completions.isEmpty ? nil : completions.removeFirst() }
  }
}

private extension NSLocking {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
