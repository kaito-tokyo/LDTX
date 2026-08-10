// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDiagnostics

/// A FIFO executor for the commands that exclusively own one resource.
///
/// The generic `Task` is the resource's command vocabulary. Callers may only
/// submit values from that vocabulary; the executor and its private scheduling
/// queue are implementation details of the resource owner.
public final class ResourceTaskQueue<Task: Sendable>: @unchecked Sendable {
  public typealias Executor =
    @Sendable (_ task: Task, _ stopToken: StopToken, _ logger: EventTaskLogger) async -> Void

  private enum State {
    case accepting
    case finishing
    case stopping
    case closing
    case finished
  }

  private let controlQueue: DispatchQueue
  private let logger: EventTaskLogger
  private let executor: Executor
  private var state = State.accepting
  private var pending: [Task] = []
  private var isRunning = false
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []

  public let stopToken = StopToken()

  public init(
    label: String,
    logger: EventTaskLogger,
    executor: @escaping Executor
  ) {
    controlQueue = DispatchQueue(label: label)
    self.logger = logger
    self.executor = executor
  }

  /// Adds one resource command. Commands are started in submission order.
  /// Once finishing or stopping begins, new commands are rejected.
  @discardableResult
  public func post(_ task: Task) -> Bool {
    controlQueue.sync {
      guard state == .accepting else { return false }
      pending.append(task)
      startNextIfNeeded()
      return true
    }
  }

  /// Stops accepting commands, drains all accepted commands, and closes the
  /// queue. Concurrent callers all return after the same terminal transition.
  public func finishAfterDraining() async {
    await waitForFinish(request: .finish)
  }

  /// Stops accepting commands, discards commands that have not started, and
  /// cooperatively signals the running command. It returns after that command
  /// exits and the queue is closed.
  public func stop() async {
    await waitForFinish(request: .stop)
  }

  private enum FinishRequest {
    case finish
    case stop
  }

  private func waitForFinish(request: FinishRequest) async {
    await withCheckedContinuation { continuation in
      controlQueue.async { [self] in
        if state == .finished {
          continuation.resume()
          return
        }
        finishWaiters.append(continuation)
        switch request {
        case .finish:
          if state == .accepting { state = .finishing }
        case .stop:
          switch state {
          case .accepting, .finishing:
            state = .stopping
            pending.removeAll()
            stopToken.requestStop()
          case .stopping, .closing, .finished:
            break
          }
        }
        advance()
      }
    }
  }

  private func startNextIfNeeded() {
    guard !isRunning else { return }
    guard !pending.isEmpty else {
      completeIfNeeded()
      return
    }
    guard state == .accepting || state == .finishing else {
      pending.removeAll()
      completeIfNeeded()
      return
    }

    let task = pending.removeFirst()
    isRunning = true
    _Concurrency.Task { [executor, stopToken, logger, weak self] in
      await executor(task, stopToken, logger)
      self?.controlQueue.async { [weak self] in
        guard let self else { return }
        isRunning = false
        advance()
      }
    }
  }

  private func advance() {
    switch state {
    case .accepting, .finishing:
      startNextIfNeeded()
    case .stopping:
      if !isRunning { completeIfNeeded() }
    case .closing, .finished:
      break
    }
  }

  private func completeIfNeeded() {
    guard !isRunning, pending.isEmpty else { return }
    guard state == .finishing || state == .stopping else { return }
    state = .closing
    _Concurrency.Task { [logger, weak self] in
      await logger.close()
      self?.controlQueue.async { [weak self] in
        guard let self, state == .closing else { return }
        state = .finished
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters {
          waiter.resume()
        }
      }
    }
  }
}
