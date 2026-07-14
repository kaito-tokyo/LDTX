// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@testable import LDTX
import Foundation
import Testing

struct BackgroundTaskQueueTests {
  @Test
  func executesFIFOAndRejectsDuplicateKey() async {
    let queue = BackgroundTaskQueue()
    let state = QueueTestState()

    let first = VisionTask(visionID: "vision") { completion in
      state.started("vision", completion: completion)
    }
    let duplicate = VisionTask(visionID: "vision") { completion in
      state.started("duplicate", completion: completion)
    }
    let automation = AutomationTask(automationID: "automation") { completion in
      state.started("automation", completion: completion)
    }

    #expect(queue.submit(first, source: .manual) { _, _ in } == true)
    #expect(queue.submit(duplicate, source: .manual) { _, _ in } == false)
    #expect(queue.submit(automation, source: .manual) { _, _ in } == true)
    #expect(state.names == ["vision"])

    state.finishNext()
    await state.waitForCount(2)
    #expect(state.names == ["vision", "automation"])
    state.finishNext()
  }

  @Test
  func discardsPeriodicSubmissionWhileBusy() {
    let queue = BackgroundTaskQueue()
    let state = QueueTestState()
    let active = VisionTask(visionID: "vision") { completion in
      state.started("vision", completion: completion)
    }
    let tick = AutomationTask(automationID: "tick") { completion in
      state.started("tick", completion: completion)
    }

    #expect(queue.submit(active, source: .manual) { _, _ in })
    #expect(queue.submit(tick, source: .periodic) { _, _ in } == false)
    state.finishNext()
  }
}

private final class QueueTestState: @unchecked Sendable {
  private let condition = NSCondition()
  private var storedNames: [String] = []
  private var completions: [@Sendable (BackgroundTaskResult) -> Void] = []

  var names: [String] {
    condition.withLock { storedNames }
  }

  func started(_ name: String, completion: @escaping @Sendable (BackgroundTaskResult) -> Void) {
    condition.withLock {
      storedNames.append(name)
      completions.append(completion)
      condition.broadcast()
    }
  }

  func finishNext() {
    let completion = condition.withLock { completions.removeFirst() }
    completion(.success)
  }

  func waitForCount(_ count: Int) async {
    while names.count < count {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}

private extension NSLocking {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
