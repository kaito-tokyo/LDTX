// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct TaskQueueStopped: Error, Equatable, Sendable {
  public init() {}
}

/// A read-only, one-shot cooperative stop signal passed into every queued task.
public final class StopToken: @unchecked Sendable {
  private let lock = NSLock()
  private var stopRequested = false

  public var isStopRequested: Bool {
    lock.withLock { stopRequested }
  }

  public func check() throws {
    if isStopRequested { throw TaskQueueStopped() }
  }

  func requestStop() {
    lock.withLock { stopRequested = true }
  }
}

/// A thin FIFO event queue. Stopping is cooperative: the running task owns
/// its shutdown and must eventually invoke its bound completion closure.
public final class EventTaskQueue: @unchecked Sendable {
  public typealias Completion = @Sendable () -> Void
  public typealias Task = @Sendable (_ stopToken: StopToken) -> Void
  public typealias TaskFactory = @Sendable (_ completion: @escaping Completion) -> Task

  private enum State {
    case accepting
    case stopping
    case stopped
  }

  private struct Entry: Sendable {
    var id: UUID
    var task: Task
  }

  public let id = UUID()
  public let stopToken = StopToken()

  private let controlQueue: DispatchQueue
  private let executionQueue: DispatchQueue
  private var state = State.accepting
  private var pending: [Entry] = []
  private var runningID: UUID?
  private var stopHandlers: [@MainActor @Sendable () -> Void] = []

  public init(label: String) {
    controlQueue = DispatchQueue(label: label)
    executionQueue = DispatchQueue(label: "\(label).execution")
  }

  /// Constructs a task after binding its one-shot completion closure. The
  /// resulting task receives only the queue-owned StopToken when executed.
  @discardableResult
  public func enqueue(_ factory: TaskFactory) -> Bool {
    controlQueue.sync {
      guard state == .accepting else { return false }
      let id = UUID()
      let completion = OneShotCompletion { [weak self] in
        self?.controlQueue.async { [weak self] in self?.finish(id: id) }
      }
      pending.append(Entry(id: id, task: factory(completion.callAsFunction)))
      startNextIfNeeded()
      return true
    }
  }

  /// Permanently stops accepting work, discards pending work, and signals the
  /// running task. It never forcibly completes or terminates that task.
  public func stop(
    completionHandler: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    controlQueue.async { [self] in
      switch state {
      case .accepting:
        state = .stopping
        stopToken.requestStop()
        pending.removeAll()
        stopHandlers.append(completionHandler)
        completeStopIfPossible()
      case .stopping:
        stopHandlers.append(completionHandler)
      case .stopped:
        notifyOnMainActor(completionHandler)
      }
    }
  }

  private func startNextIfNeeded() {
    guard state == .accepting, runningID == nil else {
      completeStopIfPossible()
      return
    }
    guard !pending.isEmpty else { return }
    let entry = pending.removeFirst()
    runningID = entry.id
    executionQueue.async { [stopToken] in
      entry.task(stopToken)
    }
  }

  private func finish(id: UUID) {
    guard runningID == id else { return }
    runningID = nil
    if state == .accepting {
      startNextIfNeeded()
    } else {
      pending.removeAll()
      completeStopIfPossible()
    }
  }

  private func completeStopIfPossible() {
    guard state == .stopping, runningID == nil else { return }
    state = .stopped
    let handlers = stopHandlers
    stopHandlers.removeAll()
    handlers.forEach(notifyOnMainActor)
  }

  private func notifyOnMainActor(_ handler: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated { handler() }
    }
  }
}

final class OneShotCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var body: (@Sendable () -> Void)?

  init(_ body: @escaping @Sendable () -> Void) {
    self.body = body
  }

  func callAsFunction() {
    let body = lock.withLock {
      let body = self.body
      self.body = nil
      return body
    }
    body?()
  }
}

private extension NSLocking {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
