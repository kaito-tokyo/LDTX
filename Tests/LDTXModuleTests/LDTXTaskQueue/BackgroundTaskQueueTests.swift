// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXTaskQueue
import Testing

@Suite(.tags(.easy))
struct SessionTaskQueueIntegrationTestSuite {
  @Test("LUB-1006: Executes fire and forget tasks serially")
  func executesFireAndForgetTasksSerially() {
    let log = BackgroundQueueTestLog()
    let queue = SessionTaskQueue(label: "test.session.serial")

    #expect(
      queue.submit(key: SessionTaskKey("first"), source: .normal, task(named: "first", log: log)))
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

  @Test("LUB-1006: Deduplicates running and pending keys") func deduplicatesRunningAndPendingKeys()
  {
    let log = BackgroundQueueTestLog()
    let queue = SessionTaskQueue(label: "test.session.deduplicate")

    #expect(
      queue.submit(key: SessionTaskKey("vision"), source: .normal, task(named: "first", log: log)))
    #expect(log.waitForStarts(1))
    #expect(
      !queue.submit(
        key: SessionTaskKey("vision"), source: .normal, task(named: "duplicate", log: log)))
    #expect(
      queue.submit(
        key: SessionTaskKey("screenshot"), source: .normal,
        task(named: "second", log: log)))
    #expect(
      !queue.submit(
        key: SessionTaskKey("screenshot"), source: .normal,
        task(named: "duplicate-pending", log: log)))
    log.completeNext()
    #expect(log.waitForStarts(2))
    #expect(log.started == ["first", "second"])
    log.completeNext()
  }

  @Test("LUB-1006: When idle skips while queue has work") func whenIdleSkipsWhileQueueHasWork() {
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

  @Test("LUB-1006: Stop signals running task drops pending and notifies on main actor")
  func stopSignalsRunningTaskDropsPendingAndNotifiesOnMainActor() async {
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

  @Test("LUB-1006: Completion is one shot") func completionIsOneShot() {
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

  @Test("LUB-1006: Finish closes submissions then runs finalizer", .timeLimit(.minutes(1)))
  func finishClosesSubmissionsThenRunsFinalizer() async throws {
    let finalizerStarted = TaskQueueAsyncSignal()
    let queue = SessionTaskQueue(label: "test.session.finish") { completion in
      { _ in
        finalizerStarted.signal()
        completion()
      }
    }
    let firstStarted = TaskQueueAsyncSignal()
    let releaseFirst = DispatchSemaphore(value: 0)
    let finishCompleted = TaskQueueAsyncSignal()

    #expect(
      queue.submit(key: SessionTaskKey("first"), source: .normal) { completion in
        { _ in
          firstStarted.signal()
          releaseFirst.wait()
          completion()
        }
      })
    await firstStarted.wait()
    queue.finish { finishCompleted.signal() }
    let laterTask: SessionTaskQueue.TaskFactory = { completion in
      { _ in completion() }
    }
    let acceptedLater = queue.submit(
      key: SessionTaskKey("later"), source: .normal, laterTask)
    #expect(!acceptedLater)
    try await Task.sleep(for: .milliseconds(10))
    #expect(!finishCompleted.isSignaled)
    #expect(!finalizerStarted.isSignaled)
    releaseFirst.signal()
    await finalizerStarted.wait()
    await finishCompleted.wait()
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

extension NSLocking {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
