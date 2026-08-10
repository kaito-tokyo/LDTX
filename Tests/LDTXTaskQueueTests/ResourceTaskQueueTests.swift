// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXTaskQueue
import Testing

struct ResourceTaskQueueTests {
  private enum Command: Sendable {
    case append(Int)
    case suspendThenAppend(Int, ResourceTaskQueueTestSignal)
  }

  @Test func executesFIFOAcrossSuspension() async {
    let started = ResourceTaskQueueTestSignal()
    let release = ResourceTaskQueueTestSignal()
    let values = ResourceTaskQueueTestValues()
    let queue = makeQueue(values: values, started: started)

    #expect(queue.post(.suspendThenAppend(1, release)))
    #expect(queue.post(.append(2)))
    await started.wait()
    #expect(values.snapshot == [])

    release.signal()
    await queue.finishAfterDraining()
    #expect(values.snapshot == [1, 2])
  }

  @Test func finishDrainsAcceptedCommandsAndRejectsNewCommands() async {
    let values = ResourceTaskQueueTestValues()
    let queue = makeQueue(values: values)
    #expect(queue.post(.append(1)))
    #expect(queue.post(.append(2)))

    await queue.finishAfterDraining()

    #expect(values.snapshot == [1, 2])
    #expect(queue.post(.append(3)) == false)
    await queue.finishAfterDraining()
  }

  @Test func stopSignalsRunningCommandAndDiscardsPendingCommands() async {
    let started = ResourceTaskQueueTestSignal()
    let release = ResourceTaskQueueTestSignal()
    let values = ResourceTaskQueueTestValues()
    let observedStop = ResourceTaskQueueTestFlag()
    let queue = ResourceTaskQueue<Command>(label: "test.resource.stop", logger: .disabled) {
      command, stopToken, _ in
      switch command {
      case .append(let value):
        values.append(value)
      case .suspendThenAppend(let value, let signal):
        started.signal()
        await signal.wait()
        observedStop.set(stopToken.isStopRequested)
        values.append(value)
      }
    }
    #expect(queue.post(.suspendThenAppend(1, release)))
    #expect(queue.post(.append(2)))
    await started.wait()

    let stopping = Task { await queue.stop() }
    while !queue.stopToken.isStopRequested { await Task.yield() }
    #expect(queue.post(.append(3)) == false)
    release.signal()
    await stopping.value

    #expect(observedStop.value)
    #expect(values.snapshot == [1])
  }

  private func makeQueue(
    values: ResourceTaskQueueTestValues,
    started: ResourceTaskQueueTestSignal? = nil
  ) -> ResourceTaskQueue<Command> {
    ResourceTaskQueue(label: "test.resource", logger: .disabled) { command, _, _ in
      switch command {
      case .append(let value):
        values.append(value)
      case .suspendThenAppend(let value, let signal):
        started?.signal()
        await signal.wait()
        values.append(value)
      }
    }
  }
}

private final class ResourceTaskQueueTestValues: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Int] = []

  var snapshot: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }

  func append(_ value: Int) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }
}

private final class ResourceTaskQueueTestFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue = false

  var value: Bool {
    lock.lock()
    defer { lock.unlock() }
    return storedValue
  }

  func set(_ value: Bool) {
    lock.lock()
    storedValue = value
    lock.unlock()
  }
}

private final class ResourceTaskQueueTestSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var signaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

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
    for waiter in waiters {
      waiter.resume()
    }
  }

  func wait() async {
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
