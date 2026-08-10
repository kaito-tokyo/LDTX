// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXTaskQueue
import Testing

struct WorkspaceResourceQueueTests {
  @Test func drainsPreparationsInFIFOOrderBeforeCleanup() async {
    let log = WorkspaceResourceQueueTestLog()
    let firstStarted = WorkspaceResourceQueueTestSignal()
    let releaseFirst = WorkspaceResourceQueueTestSignal()
    let queue = WorkspaceResourceQueue(label: "test.workspace-resources")

    #expect(
      queue.enqueue(key: .init("first")) {
        log.append("first-start")
        firstStarted.signal()
        await releaseFirst.wait()
        log.append("first-finish")
      })
    #expect(queue.enqueue(key: .init("second")) { log.append("second") })
    #expect(queue.registerCleanup(key: .init("cleanup")) { log.append("cleanup") })

    await firstStarted.wait()
    let draining = Task { await queue.drainAndCleanup() }
    while queue.isAccepting { await Task.yield() }
    #expect(queue.enqueue(key: .init("late")) {} == false)
    releaseFirst.signal()
    await draining.value

    #expect(log.snapshot == ["first-start", "first-finish", "second", "cleanup"])
  }

  @Test func deduplicatesKeysForTheQueueLifetime() async {
    let queue = WorkspaceResourceQueue(label: "test.workspace-resources.deduplicate")
    #expect(queue.enqueue(key: .init("model")) {})
    #expect(queue.enqueue(key: .init("model")) {} == false)
    #expect(queue.registerCleanup(key: .init("vision")) {})
    #expect(queue.registerCleanup(key: .init("vision")) {} == false)
    await queue.drainAndCleanup()
    #expect(queue.enqueue(key: .init("another")) {} == false)
  }

  @Test func concurrentDrainCallersWaitForOneCleanup() async {
    let log = WorkspaceResourceQueueTestLog()
    let queue = WorkspaceResourceQueue(label: "test.workspace-resources.concurrent-drain")
    #expect(queue.registerCleanup(key: .init("cleanup")) { log.append("cleanup") })

    async let first: Void = queue.drainAndCleanup()
    async let second: Void = queue.drainAndCleanup()
    _ = await (first, second)

    #expect(log.snapshot == ["cleanup"])
  }
}

private final class WorkspaceResourceQueueTestLog: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []

  var snapshot: [String] {
    lock.withLock { values }
  }

  func append(_ value: String) {
    lock.withLock { values.append(value) }
  }
}

private final class WorkspaceResourceQueueTestSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var signaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func signal() {
    let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
      guard !signaled else { return [] }
      signaled = true
      let waiters = self.waiters
      self.waiters.removeAll()
      return waiters
    }
    waiters.forEach { $0.resume() }
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      let shouldResume = lock.withLock {
        if signaled { return true }
        waiters.append(continuation)
        return false
      }
      if shouldResume { continuation.resume() }
    }
  }
}
