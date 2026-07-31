// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct BackgroundTaskKey: Hashable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

public enum BackgroundTaskSubmission: Equatable, Sendable {
  case manual
  case periodic
}

/// A serial queue for best-effort work that may be discarded during shutdown.
///
/// At most one task per key may be running or pending. `stop()` rejects new
/// submissions, discards pending work, and cooperatively cancels the running
/// task without draining the queue.
public final class BackgroundTaskQueue: @unchecked Sendable {
  public typealias Completion = @Sendable () -> Void
  public typealias Task = @Sendable (_ stopToken: StopToken) -> Void
  public typealias TaskFactory = @Sendable (_ completion: @escaping Completion) -> Task

  private enum State { case accepting, stopping, stopped }

  private struct Entry: Sendable {
    var id: UUID
    var key: BackgroundTaskKey
    var task: Task
  }

  public let stopToken = StopToken()
  private let controlQueue: DispatchQueue
  private let executionQueue: DispatchQueue
  private var state = State.accepting
  private var pending: [Entry] = []
  private var running: Entry?
  private var stopHandlers: [@MainActor @Sendable () -> Void] = []

  public init(label: String) {
    controlQueue = DispatchQueue(label: label)
    executionQueue = DispatchQueue(label: "\(label).execution")
  }

  @discardableResult
  public func submit(
    key: BackgroundTaskKey,
    source _: BackgroundTaskSubmission,
    _ factory: TaskFactory
  ) -> Bool {
    controlQueue.sync {
      guard state == .accepting,
        running?.key != key,
        !pending.contains(where: { $0.key == key })
      else { return false }

      let id = UUID()
      let completion = BackgroundOneShotCompletion { [weak self] in
        self?.controlQueue.async { [weak self] in self?.finish(id: id) }
      }
      pending.append(Entry(id: id, key: key, task: factory(completion.callAsFunction)))
      startNextIfNeeded()
      return true
    }
  }

  public func stop(
    completionHandler: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    controlQueue.sync { [self] in
      switch state {
      case .accepting:
        state = .stopping
        pending.removeAll()
        stopHandlers.append(completionHandler)
        stopToken.requestStop()
        completeStopIfPossible()
      case .stopping:
        stopHandlers.append(completionHandler)
      case .stopped:
        notifyOnMainActor(completionHandler)
      }
    }
  }

  private func startNextIfNeeded() {
    guard state == .accepting, running == nil else {
      completeStopIfPossible()
      return
    }
    guard !pending.isEmpty else { return }
    let entry = pending.removeFirst()
    running = entry
    executionQueue.async { [stopToken] in entry.task(stopToken) }
  }

  private func finish(id: UUID) {
    guard running?.id == id else { return }
    running = nil
    if state == .accepting { startNextIfNeeded() }
    else { completeStopIfPossible() }
  }

  private func completeStopIfPossible() {
    guard state == .stopping, running == nil else { return }
    state = .stopped
    let handlers = stopHandlers
    stopHandlers.removeAll()
    handlers.forEach(notifyOnMainActor)
  }

  private func notifyOnMainActor(_ handler: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated { handler() } }
  }
}

private final class BackgroundOneShotCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var body: (@Sendable () -> Void)?

  init(_ body: @escaping @Sendable () -> Void) { self.body = body }

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
