// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// An application-defined identifier for a Session task.
public struct SessionTaskKey: Hashable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Selects whether a Session task may begin while other work is queued.
public enum SessionTaskSubmission: Equatable, Sendable {
  /// Accept the task unless another task with the same key is pending or running.
  case normal
  /// Accept the task only when the queue has no pending or running work.
  case whenIdle
}

/// A single-use FIFO queue for work that belongs to one Session.
///
/// `finish` permanently closes submissions, completes work accepted before the
/// call, then executes the injected Finalize task exactly once. The queue does
/// not know what the tasks or Finalize operation do.
public final class SessionTaskQueue: @unchecked Sendable {
  public typealias Completion = @Sendable () -> Void
  public typealias Task = @Sendable (_ stopToken: StopToken) -> Void
  public typealias TaskFactory = @Sendable (_ completion: @escaping Completion) -> Task

  private enum State: Equatable {
    case accepting
    case finishing
    case finalizing
    case stopping
    case finished
  }

  private struct Entry: Sendable {
    var id: UUID
    var key: SessionTaskKey
    var task: Task
  }

  public let stopToken = StopToken()

  private let controlQueue: DispatchQueue
  private let executionQueue: DispatchQueue
  private let finalizer: TaskFactory
  private var state = State.accepting
  private var pending: [Entry] = []
  private var runningID: UUID?
  private var runningKey: SessionTaskKey?
  private var finishHandlers: [@MainActor @Sendable () -> Void] = []

  public init(label: String, finalizer: @escaping TaskFactory = { completion in
    { _ in completion() }
  }) {
    controlQueue = DispatchQueue(label: label)
    executionQueue = DispatchQueue(label: "\(label).execution")
    self.finalizer = finalizer
  }

  /// Submits Session-owned work. A finished or finishing queue rejects work.
  @discardableResult
  public func submit(
    key: SessionTaskKey,
    source: SessionTaskSubmission,
    _ factory: TaskFactory
  ) -> Bool {
    controlQueue.sync {
      guard state == .accepting else { return false }
      switch source {
      case .normal:
        guard runningKey != key, !pending.contains(where: { $0.key == key })
        else { return false }
      case .whenIdle:
        guard runningID == nil, pending.isEmpty else { return false }
      }

      let id = UUID()
      let completion = OneShotCompletion { [weak self] in
        self?.controlQueue.async { [weak self] in self?.completeTask(id: id) }
      }
      pending.append(Entry(id: id, key: key, task: factory(completion.callAsFunction)))
      advance()
      return true
    }
  }

  /// Closes submissions and finishes this Session. The Finalize task runs after
  /// every task accepted before this call completes.
  public func finish(
    completionHandler: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    controlQueue.sync {
      switch state {
      case .accepting:
        state = .finishing
        finishHandlers.append(completionHandler)
        advance()
      case .finishing, .finalizing, .stopping:
        finishHandlers.append(completionHandler)
      case .finished:
        notifyOnMainActor(completionHandler)
      }
    }
  }

  /// Cooperatively stops this queue after an abnormal Session termination.
  /// Pending work is discarded and the normal Finalize task is not started.
  /// Callers must invoke this before the Finalize task begins; behavior is
  /// unspecified after Finalize has started.
  public func stop(
    completionHandler: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    controlQueue.sync {
      switch state {
      case .accepting, .finishing:
        state = .stopping
        stopToken.requestStop()
        pending.removeAll()
        finishHandlers.append(completionHandler)
        advance()
      case .finalizing, .stopping:
        finishHandlers.append(completionHandler)
      case .finished:
        notifyOnMainActor(completionHandler)
      }
    }
  }

  private func advance() {
    guard runningID == nil else { return }
    switch state {
    case .accepting, .finishing:
      if !pending.isEmpty {
        start(pending.removeFirst())
      } else {
        switch state {
        case .finishing: startFinalizer()
        case .accepting, .finalizing, .stopping, .finished: break
        }
      }
    case .stopping:
      completeFinish()
    case .finalizing, .finished:
      break
    }
  }

  private func start(_ entry: Entry) {
    runningID = entry.id
    runningKey = entry.key
    executionQueue.async { [stopToken] in entry.task(stopToken) }
  }

  private func startFinalizer() {
    state = .finalizing
    let id = UUID()
    runningID = id
    runningKey = nil
    let completion = OneShotCompletion { [weak self] in
      self?.controlQueue.async { [weak self] in self?.completeFinalizer(id: id) }
    }
    let task = finalizer(completion.callAsFunction)
    executionQueue.async { [stopToken] in task(stopToken) }
  }

  private func completeTask(id: UUID) {
    guard runningID == id else { return }
    runningID = nil
    runningKey = nil
    advance()
  }

  private func completeFinalizer(id: UUID) {
    guard state == .finalizing, runningID == id else { return }
    runningID = nil
    completeFinish()
  }

  private func completeFinish() {
    guard runningID == nil else { return }
    switch state {
    case .finalizing, .stopping: break
    case .accepting, .finishing, .finished: return
    }
    state = .finished
    let handlers = finishHandlers
    finishHandlers.removeAll()
    handlers.forEach(notifyOnMainActor)
  }

  private func notifyOnMainActor(_ handler: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated { handler() }
    }
  }
}
