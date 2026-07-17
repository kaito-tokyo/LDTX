// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXTaskQueue
import Testing

struct BackgroundTaskQueueTests {
  @Test func executesFireAndForgetTasksSerially() {
    let log = BackgroundQueueTestLog()
    let queue = BackgroundTaskQueue(label: "test.background.serial")

    #expect(queue.submit(key: .vision("first"), source: .manual, task(named: "first", log: log)))
    #expect(
      queue.submit(
        key: .automation("second"), source: .manual, task(named: "second", log: log)))
    #expect(log.waitForStarts(1))
    #expect(log.started == ["first"])
    log.completeNext()
    #expect(log.waitForStarts(2))
    #expect(log.started == ["first", "second"])
    log.completeNext()
  }

  @Test func deduplicatesRunningAndPendingKeys() {
    let log = BackgroundQueueTestLog()
    let queue = BackgroundTaskQueue(label: "test.background.deduplicate")

    #expect(queue.submit(key: .vision("vision"), source: .manual, task(named: "first", log: log)))
    #expect(log.waitForStarts(1))
    #expect(
      !queue.submit(
        key: .vision("vision"), source: .manual, task(named: "duplicate", log: log)))
    #expect(
      queue.submit(
        key: .automation("automation"), source: .manual,
        task(named: "second", log: log)))
    #expect(
      !queue.submit(
        key: .automation("automation"), source: .postAction,
        task(named: "duplicate-pending", log: log)))
    log.completeNext()
    #expect(log.waitForStarts(2))
    #expect(log.started == ["first", "second"])
    log.completeNext()
  }

  @Test func whenIdleSkipsWhileQueueHasWork() {
    let log = BackgroundQueueTestLog()
    let queue = BackgroundTaskQueue(label: "test.background.when-idle")

    #expect(
      queue.submit(
        key: .vision("manual"), source: .manual, task(named: "manual", log: log)))
    #expect(log.waitForStarts(1))
    #expect(
      !queue.submit(
        key: .automation("periodic"),
        source: .periodic,
        task(named: "periodic", log: log)
      ))
    log.completeNext()
  }

  @Test func stopSignalsRunningTaskDropsPendingAndNotifiesOnMainActor() async {
    let log = BackgroundQueueTestLog()
    let queue = BackgroundTaskQueue(label: "test.background.stop")

    #expect(
      queue.submit(
        key: .vision("running"), source: .manual, task(named: "running", log: log)))
    #expect(
      queue.submit(
        key: .automation("pending"), source: .manual, task(named: "pending", log: log)))
    #expect(log.waitForStarts(1))

    await withCheckedContinuation { continuation in
      queue.stop {
        MainActor.preconditionIsolated()
        continuation.resume()
      }
      #expect(waitUntil { queue.stopToken.isStopRequested })
      #expect(
        !queue.submit(
          key: .vision("rejected"), source: .manual,
          task(named: "rejected", log: log)))
      log.completeNext()
    }

    #expect(log.started == ["running"])
  }

  @Test func completionIsOneShot() {
    let log = BackgroundQueueTestLog()
    let queue = BackgroundTaskQueue(label: "test.background.oneshot")
    #expect(
      queue.submit(key: .vision("first"), source: .manual, task(named: "first", log: log)))
    #expect(
      queue.submit(
        key: .automation("second"), source: .manual, task(named: "second", log: log)))
    #expect(log.waitForStarts(1))
    let completion = log.removeNextCompletion()
    completion?()
    completion?()
    #expect(log.waitForStarts(2))
    #expect(log.started == ["first", "second"])
    log.completeNext()
  }

  private func task(
    named name: String,
    log: BackgroundQueueTestLog
  ) -> BackgroundTaskQueue.TaskFactory {
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
