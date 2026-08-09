// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDiagnostics
import LDTXTaskQueue
import Testing

struct EventTaskQueueTests {
  @Test func passesTheInjectedLoggerToTheTask() throws {
    let logger = EventTaskLogger.disabled
    let received = DispatchSemaphore(value: 0)
    let queue = EventTaskQueue(label: "test.logger", logger: logger)
    #expect(
      queue.enqueue { completion in
        { _, taskLogger in
          if taskLogger !== logger { Issue.record("Task received a different logger") }
          received.signal()
          completion()
        }
      })
    #expect(received.wait(timeout: .now() + 1) == .success)
  }

  @Test func executesFIFOAndWaitsForBoundCompletion() throws {
    let log = TaskQueueTestLog()
    let queue = EventTaskQueue(label: "test.fifo", logger: .disabled)

    #expect(queue.enqueue(task(named: "first", log: log)))
    #expect(queue.enqueue(task(named: "second", log: log)))
    #expect(log.waitForStarts(1))
    #expect(log.started == ["first"])

    log.completeNext()
    #expect(log.waitForStarts(2))
    #expect(log.started == ["first", "second"])
    log.completeNext()
  }

  @Test(.timeLimit(.minutes(1)))
  func stopSignalsRunningTaskAndCompletesDiscardedPendingTasks() async throws {
    let log = TaskQueueTestLog()
    let stopped = TaskQueueAsyncSignal()
    let discarded = TaskQueueAsyncSignal()
    let queue = EventTaskQueue(label: "test.stop", logger: .disabled)

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

  @Test func completionIsOneShot() throws {
    let log = TaskQueueTestLog()
    let queue = EventTaskQueue(label: "test.oneshot", logger: .disabled)
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

  private func task(named name: String, log: TaskQueueTestLog) -> EventTaskQueue.TaskFactory {
    { completion in
      { stopToken, _ in
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
