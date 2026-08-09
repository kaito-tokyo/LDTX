// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDiagnostics

public struct TaskQueueStopped: Error, Equatable, Sendable {
  public init() {}
}

/// A read-only, one-shot cooperative stop signal passed into every queued task.
public final class StopToken: @unchecked Sendable {
  public static let neverStopped = StopToken()

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
  public typealias Task = @Sendable (_ stopToken: StopToken, _ logger: EventTaskLogger) -> Void
  public typealias TaskFactory = @Sendable (_ completion: @escaping Completion) -> Task

  private enum State {
    case accepting
    case stopping
    case stopped
  }

  private struct Entry: Sendable {
    var id: UUID
    var task: Task
    var discard: Completion
  }

  public let id = UUID()
  public let stopToken = StopToken()

  private let controlQueue: DispatchQueue
  private let executionQueue: DispatchQueue
  private let logger: EventTaskLogger
  private var state = State.accepting
  private var pending: [Entry] = []
  private var runningID: UUID?
  private var stopHandlers: [@MainActor @Sendable () -> Void] = []

  public init(label: String, logger: EventTaskLogger) {
    controlQueue = DispatchQueue(label: label)
    executionQueue = DispatchQueue(label: "\(label).execution")
    self.logger = logger
  }

  /// Constructs a task after binding its one-shot completion closure. The
  /// resulting task receives the queue-owned StopToken and logger when executed.
  @discardableResult
  public func enqueue(
    onDiscard: @escaping Completion = {},
    _ factory: TaskFactory
  ) -> Bool {
    controlQueue.sync {
      guard state == .accepting else { return false }
      let id = UUID()
      let completion = OneShotCompletion { [weak self] in
        self?.controlQueue.async { [weak self] in self?.finish(id: id) }
      }
      pending.append(
        Entry(
          id: id,
          task: factory(completion.callAsFunction),
          discard: OneShotCompletion {
            onDiscard()
            completion()
          }.callAsFunction
        ))
      startNextIfNeeded()
      return true
    }
  }

  /// Permanently stops accepting work, reports discarded pending work, and
  /// signals the running task. It never forcibly completes or terminates that task.
  public func stop(
    completionHandler: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    controlQueue.async { [self] in
      switch state {
      case .accepting:
        state = .stopping
        stopToken.requestStop()
        discardPending()
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
    executionQueue.async { [stopToken, logger] in
      entry.task(stopToken, logger)
    }
  }

  private func finish(id: UUID) {
    guard runningID == id else { return }
    runningID = nil
    if state == .accepting {
      startNextIfNeeded()
    } else {
      discardPending()
      completeStopIfPossible()
    }
  }

  private func discardPending() {
    let entries = pending
    pending.removeAll()
    for entry in entries { entry.discard() }
  }

  private func completeStopIfPossible() {
    guard state == .stopping, runningID == nil else { return }
    state = .stopped
    let handlers = stopHandlers
    stopHandlers.removeAll()
    _Concurrency.Task { [logger] in
      await logger.close()
      handlers.forEach(notifyOnMainActor)
    }
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

extension NSLocking {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
