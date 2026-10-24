// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXTaskQueue
import Testing

@Suite(.tags(.easy))
struct EventTaskQueueIntegrationTestSuite {
  @Test(
    "LUB-1006: Stall remains after running completion and rejects every pending entry",
    .timeLimit(.minutes(1)))
  func stallRemainsAfterRunningCompletionAndRejectsEveryPendingEntry() async {
    let log = TaskQueueTestLog()
    let queue = EventTaskQueue(label: "test.stall-completion")
    let firstDiscard = TaskQueueAsyncSignal()
    let secondDiscard = TaskQueueAsyncSignal()
    let notified = TaskQueueAsyncSignal()
    let stopped = TaskQueueAsyncSignal()
    #expect(queue.enqueue(task(named: "failing", log: log)))
    #expect(log.waitForStarts(1))
    let acceptedFirst = queue.enqueue(
      onDiscard: { firstDiscard.signal() }, task(named: "first", log: log))
    let acceptedSecond = queue.enqueue(
      onDiscard: { secondDiscard.signal() }, task(named: "second", log: log))
    #expect(acceptedFirst)
    #expect(acceptedSecond)
    queue.stall { notified.signal() }
    log.completeNext()
    queue.stall { Issue.record("Stall notification must be one-shot") }
    await notified.wait()
    await firstDiscard.wait()
    await secondDiscard.wait()
    #expect(!queue.enqueue(task(named: "retry", log: log)))
    queue.stop { stopped.signal() }
    await stopped.wait()
    #expect(log.started == ["failing"])
  }

  @Test(
    "LUB-1006: Stall rejects pending work and notifies before cleanup completes",
    .timeLimit(.minutes(1)))
  func stallRejectsPendingWorkAndNotifiesBeforeCleanupCompletes() async {
    let log = TaskQueueTestLog()
    let queue = EventTaskQueue(label: "test.stall")
    let notified = TaskQueueAsyncSignal()
    let cleanupStarted = TaskQueueAsyncSignal()
    let cleanupFinished = TaskQueueAsyncSignal()
    let releaseCleanup = DispatchSemaphore(value: 0)
    let stopped = TaskQueueAsyncSignal()
    defer { releaseCleanup.signal() }

    #expect(queue.enqueue(task(named: "running", log: log)))
    #expect(log.waitForStarts(1))
    let acceptedPending = queue.enqueue(
      onDiscard: {
        cleanupStarted.signal()
        #expect(!queue.enqueue(self.task(named: "discard-retry", log: log)))
        #expect(releaseCleanup.wait(timeout: .now() + 5) == .success)
        cleanupFinished.signal()
      }, task(named: "pending", log: log))
    #expect(acceptedPending)
    queue.stall { notified.signal() }
    await cleanupStarted.wait()
    await notified.wait()
    #expect(!cleanupFinished.isSignaled)
    #expect(!queue.stopToken.isStopRequested)
    #expect(!queue.enqueue(task(named: "rejected", log: log)))
    #expect(log.started == ["running"])

    queue.stop { stopped.signal() }
    #expect(!stopped.isSignaled)
    log.completeNext()
    releaseCleanup.signal()
    await stopped.wait()
    #expect(log.started == ["running"])
  }

  @Test("LUB-1006: Stalled workspace does not block another queue", .timeLimit(.minutes(1)))
  func stalledWorkspaceDoesNotBlockAnotherQueue() async {
    let first = EventTaskQueue(label: "test.workspace.first")
    let second = EventTaskQueue(label: "test.workspace.second")
    let firstLog = TaskQueueTestLog()
    let secondLog = TaskQueueTestLog()
    let notified = TaskQueueAsyncSignal()
    #expect(first.enqueue(task(named: "held", log: firstLog)))
    #expect(firstLog.waitForStarts(1))
    first.stall { notified.signal() }
    await notified.wait()
    #expect(second.enqueue(task(named: "independent", log: secondLog)))
    #expect(secondLog.waitForStarts(1))
    secondLog.completeNext()
    firstLog.completeNext()
  }

  @Test("LUB-1006: Executes FIFO and waits for bound completion")
  func executesFIFOAndWaitsForBoundCompletion() throws {
    let log = TaskQueueTestLog()
    let queue = EventTaskQueue(label: "test.fifo")

    #expect(queue.enqueue(task(named: "first", log: log)))
    #expect(queue.enqueue(task(named: "second", log: log)))
    #expect(log.waitForStarts(1))
    #expect(log.started == ["first"])

    log.completeNext()
    #expect(log.waitForStarts(2))
    #expect(log.started == ["first", "second"])
    log.completeNext()
  }

  @Test(
    "LUB-1006: Stop signals running task and completes discarded pending tasks",
    .timeLimit(.minutes(1)))
  func stopSignalsRunningTaskAndCompletesDiscardedPendingTasks() async throws {
    let log = TaskQueueTestLog()
    let stopped = TaskQueueAsyncSignal()
    let discarded = TaskQueueAsyncSignal()
    let queue = EventTaskQueue(label: "test.stop")

    #expect(queue.enqueue(task(named: "running", log: log)))
    let acceptedPending = queue.enqueue(
      onDiscard: { discarded.signal() }, task(named: "pending", log: log))
    #expect(acceptedPending)
    #expect(log.waitForStarts(1))
    queue.stop {
      MainActor.preconditionIsolated()
      stopped.signal()
    }

    #expect(waitUntil { queue.stopToken.isStopRequested })
    #expect(log.started == ["running"])
    #expect(queue.enqueue(task(named: "rejected", log: log)) == false)
    await discarded.wait()
    try await Task.sleep(for: .milliseconds(20))
    #expect(!stopped.isSignaled)

    log.completeNext()
    await stopped.wait()
    #expect(log.started == ["running"])
  }

  @Test("LUB-1006: Completion is one shot") func completionIsOneShot() throws {
    let log = TaskQueueTestLog()
    let queue = EventTaskQueue(label: "test.oneshot")
    #expect(queue.enqueue(task(named: "first", log: log)))
    #expect(queue.enqueue(task(named: "second", log: log)))
    #expect(log.waitForStarts(1))

    let completion = try #require(log.removeNextCompletion())
    completion()
    completion()
    #expect(log.waitForStarts(2))
    #expect(log.started == ["first", "second"])
    log.completeNext()
  }

  @Test(
    "LUB-1006: Discarded task can synchronously attempt another enqueue", .timeLimit(.minutes(1)))
  func discardedTaskCanSynchronouslyAttemptAnotherEnqueue() async {
    let log = TaskQueueTestLog()
    let discarded = TaskQueueAsyncSignal()
    let stopped = TaskQueueAsyncSignal()
    let queue = EventTaskQueue(label: "test.discard-reenqueue")

    #expect(queue.enqueue(task(named: "running", log: log)))
    let acceptedPending = queue.enqueue(
      onDiscard: {
        #expect(queue.enqueue(self.task(named: "retry", log: log)) == false)
        discarded.signal()
      },
      task(named: "pending", log: log))
    #expect(acceptedPending)
    #expect(log.waitForStarts(1))

    queue.stop { stopped.signal() }
    log.completeNext()
    await discarded.wait()
    await stopped.wait()
    #expect(log.started == ["running"])
  }

  private func task(named name: String, log: TaskQueueTestLog) -> EventTaskQueue.TaskFactory {
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

final class TaskQueueAsyncSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var signaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  var isSignaled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return signaled
  }

  func signal() {
    lock.lock()
    guard !signaled else {
      lock.unlock()
      return
    }
    signaled = true
    let waiters = waiters
    self.waiters.removeAll()
    lock.unlock()
    for waiter in waiters { waiter.resume() }
  }

  func wait() async {
    if isSignaled { return }
    await withCheckedContinuation { continuation in
      lock.lock()
      if signaled {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }
}

private final class TaskQueueTestLog: @unchecked Sendable {
  private let condition = NSCondition()
  private var storedStarted: [String] = []
  private var completions: [@Sendable () -> Void] = []
  private var tokens: [StopToken] = []

  var started: [String] { condition.withLock { storedStarted } }

  func start(
    _ name: String,
    stopToken: StopToken,
    completion: @escaping @Sendable () -> Void
  ) {
    condition.withLock {
      storedStarted.append(name)
      tokens.append(stopToken)
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
