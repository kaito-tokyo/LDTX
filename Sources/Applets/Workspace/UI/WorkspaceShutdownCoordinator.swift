// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDiagnostics
import LDTXTaskQueue
import os

/// Owns the one-way transition from a live Workspace to a fully stopped one.
///
/// Output-session operations are deliberately not routed through this type.
/// Closing the Workspace is the final recovery boundary that enumerates and
/// stops every resource, including resources left behind by partial failures.
final class WorkspaceShutdownCoordinator: Sendable {
  typealias ResourceOperation = @MainActor @Sendable (StopToken) async -> Void
  typealias StartRequest = ResourceOperation
  typealias StopOperation = @MainActor @Sendable () async -> Void
  typealias Verification = @Sendable () async -> Bool
  typealias Completion = @MainActor @Sendable () -> Void

  private let logger = Logger(subsystem: "tokyo.kaito.ldtx", category: "WorkspaceShutdown")

  private struct State: Sendable {
    var isStopping = false
    var isFullyStopped = false
    var verificationFailed = false
  }

  private enum ShutdownAction {
    case begin
    case retryVerification
    case reject
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let resourceQueue: EventTaskQueue
  private let verificationTimeout: Duration

  init(
    logger: EventTaskLogger,
    verificationTimeout: Duration = .seconds(30)
  ) {
    self.verificationTimeout = verificationTimeout
    resourceQueue = EventTaskQueue(
      label: "tokyo.kaito.ldtx.workspace.resources",
      logger: logger
    )
  }

  /// Atomically admits a resource-control event before shutdown begins.
  @discardableResult
  func requestStart(_ request: @escaping StartRequest) -> Bool {
    state.withLock { state in
      guard !state.isStopping, !state.isFullyStopped, !state.verificationFailed else {
        return false
      }
      return resourceQueue.enqueue { finish in
        { stopToken, _ in
          Task { @MainActor in
            defer { finish() }
            guard !stopToken.isStopRequested else { return }
            await request(stopToken)
          }
        }
      }
    }
  }

  /// Waits only for the resource event admitted by this call. The queue itself
  /// does not expose idle state or transport the result.
  @MainActor
  func requestStartAndWait(
    _ request: @escaping @MainActor @Sendable (StopToken) async -> Bool
  ) async -> Bool {
    let result = WorkspaceResourceEventResult()
    let accepted = state.withLock { state in
      guard !state.isStopping, !state.isFullyStopped, !state.verificationFailed else {
        return false
      }
      return resourceQueue.enqueue(
        onDiscard: {
          Task { @MainActor in result.finish(false) }
        },
        { finish in
          { stopToken, _ in
            Task { @MainActor in
              defer { finish() }
              guard !stopToken.isStopRequested else {
                result.finish(false)
                return
              }
              result.finish(await request(stopToken))
            }
          }
        })
    }
    guard accepted else {
      return false
    }
    return await result.wait()
  }

  @discardableResult
  func beginShutdown(
    _ operation: @escaping StopOperation,
    verifyStopped: @escaping Verification,
    completion: @escaping Completion = {}
  ) -> Bool {
    let action = state.withLock { state -> ShutdownAction in
      guard !state.isStopping, !state.isFullyStopped else { return .reject }
      if state.verificationFailed {
        state.verificationFailed = false
        state.isStopping = true
        return .retryVerification
      }
      state.isStopping = true
      return .begin
    }
    switch action {
    case .begin:
      resourceQueue.stop { [self] in
        Task { @MainActor in
          await performStopAndReset(
            operation, verifyStopped: verifyStopped, completion: completion)
        }
      }
      return true
    case .retryVerification:
      Task { @MainActor in
        await performVerification(verifyStopped, completion: completion)
      }
      return true
    case .reject:
      return false
    }
  }

  @MainActor
  private func performStopAndReset(
    _ operation: @escaping StopOperation,
    verifyStopped: @escaping Verification,
    completion: @escaping Completion = {}
  ) async {
    logger.notice("Workspace shutdown started")
    await operation()
    await performVerification(verifyStopped, completion: completion)
  }

  @MainActor
  private func performVerification(
    _ verifyStopped: @escaping Verification,
    completion: @escaping Completion
  ) async {
    let deadline = ContinuousClock.now + verificationTimeout
    var verifiedStopped = false
    while true {
      let remaining = ContinuousClock.now.duration(to: deadline)
      guard remaining > .zero else { break }
      guard let verification = await awaitVerification(verifyStopped, timeout: remaining) else {
        logger.error(
          "Workspace shutdown verification did not complete before its deadline; preserving the stopped control-plane state"
        )
        break
      }
      if verification {
        verifiedStopped = true
        break
      }
      if Task.isCancelled {
        logger.error(
          "Workspace shutdown verification was cancelled; preserving the stopped control-plane state"
        )
        break
      }
      do {
        try await Task.sleep(for: .milliseconds(100))
      } catch {
        logger.error(
          "Workspace shutdown verification was cancelled; preserving the stopped control-plane state"
        )
        break
      }
    }
    let didVerifyStopped = verifiedStopped
    state.withLock { state in
      state.isStopping = false
      state.isFullyStopped = didVerifyStopped
      state.verificationFailed = !didVerifyStopped
    }
    guard didVerifyStopped else { return }
    logger.notice("Workspace shutdown completed; all resources are stopped")
    completion()
  }

  private func awaitVerification(
    _ verification: @escaping Verification,
    timeout: Duration
  ) async -> Bool? {
    await withCheckedContinuation { continuation in
      let race = WorkspaceVerificationRace(continuation: continuation)
      let verificationTask = Task {
        race.finish(await verification())
      }
      let timeoutTask = Task {
        do {
          try await Task.sleep(for: timeout)
        } catch {
          return
        }
        race.finish(nil)
      }
      race.installTasks([verificationTask, timeoutTask])
    }
  }

  func shouldAllowResourceStart() -> Bool {
    state.withLock { !$0.isStopping && !$0.isFullyStopped && !$0.verificationFailed }
  }

  func resourcesAreFullyStopped() -> Bool {
    state.withLock { $0.isFullyStopped }
  }

}

private final class WorkspaceVerificationRace: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Bool?, Never>?
  private var tasks: [Task<Void, Never>] = []

  init(continuation: CheckedContinuation<Bool?, Never>) {
    self.continuation = continuation
  }

  func installTasks(_ tasks: [Task<Void, Never>]) {
    let shouldCancel = lock.withLock {
      guard continuation != nil else { return true }
      self.tasks = tasks
      return false
    }
    if shouldCancel {
      for task in tasks { task.cancel() }
    }
  }

  func finish(_ result: Bool?) {
    let (continuation, tasks) = lock.withLock {
      let continuation = self.continuation
      self.continuation = nil
      let tasks = self.tasks
      self.tasks = []
      return (continuation, tasks)
    }
    for task in tasks { task.cancel() }
    continuation?.resume(returning: result)
  }
}

@MainActor
private final class WorkspaceResourceEventResult {
  private(set) var value: Bool?
  private var waiters: [CheckedContinuation<Bool, Never>] = []

  func finish(_ value: Bool) {
    guard self.value == nil else { return }
    self.value = value
    let waiters = waiters
    self.waiters.removeAll()
    for waiter in waiters { waiter.resume(returning: value) }
  }

  func wait() async -> Bool {
    if let value { return value }
    return await withCheckedContinuation { continuation in
      if let value {
        continuation.resume(returning: value)
      } else {
        waiters.append(continuation)
      }
    }
  }
}
