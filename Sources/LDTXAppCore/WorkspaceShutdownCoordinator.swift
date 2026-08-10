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
      guard !state.isStopping, !state.isFullyStopped else { return false }
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
      guard !state.isStopping, !state.isFullyStopped else { return false }
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
    state.withLock { state in
      guard !state.isStopping, !state.isFullyStopped else { return false }
      state.isStopping = true
      resourceQueue.stop { [self] in
        Task { @MainActor in
          await performStopAndReset(
            operation, verifyStopped: verifyStopped, completion: completion)
        }
      }
      return true
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
    let deadline = ContinuousClock.now + verificationTimeout
    while !(await verifyStopped()) {
      if Task.isCancelled || ContinuousClock.now >= deadline {
        logger.error(
          "Workspace shutdown verification did not complete before its deadline; preserving the stopped control-plane state"
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
    state.withLock { state in
      state.isStopping = false
      state.isFullyStopped = true
    }
    logger.notice("Workspace shutdown completed; all resources are stopped")
    completion()
  }

  func shouldAllowResourceStart() -> Bool {
    state.withLock { !$0.isStopping && !$0.isFullyStopped }
  }

  func resourcesAreFullyStopped() -> Bool {
    state.withLock { $0.isFullyStopped }
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
