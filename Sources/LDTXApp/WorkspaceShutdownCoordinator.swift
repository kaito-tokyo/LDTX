// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

/// Owns the one-way transition from a live Workspace to a fully stopped one.
///
/// Output-session operations are deliberately not routed through this type.
/// Closing the Workspace is the final recovery boundary that enumerates and
/// stops every resource, including resources left behind by partial failures.
final class WorkspaceShutdownCoordinator: Sendable {
  typealias ResourceOperation = @MainActor @Sendable () async -> Void
  typealias StartRequest = ResourceOperation
  typealias StopOperation = ResourceOperation
  typealias Verification = @Sendable () async -> Bool
  typealias Completion = @MainActor @Sendable () -> Void

  private let logger = Logger(subsystem: "tokyo.kaito.ldtx", category: "WorkspaceShutdown")

  private struct State: Sendable {
    var isStopping = false
    var isFullyStopped = false
  }

  private struct QueueState: Sendable {
    var pendingOperations: [ResourceOperation] = []
    var isProcessing = false
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let queueState = OSAllocatedUnfairLock(initialState: QueueState())
  private let resourceQueue = DispatchQueue(label: "tokyo.kaito.ldtx.workspace.resources")

  /// Atomically admits a start request and places it ahead of any later
  /// Workspace shutdown request on the shared resource queue.
  @discardableResult
  func requestStart(_ request: @escaping StartRequest) -> Bool {
    state.withLock { state in
      guard !state.isStopping, !state.isFullyStopped else { return false }
      queueState.withLock { $0.pendingOperations.append(request) }
      resourceQueue.async { [self] in processNextIfNeeded() }
      return true
    }
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
      queueState.withLock { queueState in
        queueState.pendingOperations.append {
          await self.performStopAndReset(
            operation,
            verifyStopped: verifyStopped,
            completion: completion
          )
        }
      }
      resourceQueue.async { [self] in processNextIfNeeded() }
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
    while !(await verifyStopped()) {
      try? await Task.sleep(for: .milliseconds(100))
    }
    state.withLock { state in
      state.isStopping = false
      state.isFullyStopped = true
    }
    logger.notice("Workspace shutdown completed; all resources are stopped")
    completion()
  }

  private func processNextIfNeeded() {
    dispatchPrecondition(condition: .onQueue(resourceQueue))
    guard let operation = queueState.withLock({ queueState -> ResourceOperation? in
      guard !queueState.isProcessing, !queueState.pendingOperations.isEmpty else { return nil }
      queueState.isProcessing = true
      return queueState.pendingOperations.removeFirst()
    }) else { return }
    Task { @MainActor in
      await operation()
      resourceQueue.async { [self] in
        queueState.withLock { $0.isProcessing = false }
        processNextIfNeeded()
      }
    }
  }

  func shouldAllowResourceStart() -> Bool {
    state.withLock { !$0.isStopping && !$0.isFullyStopped }
  }

  func resourcesAreFullyStopped() -> Bool {
    state.withLock { $0.isFullyStopped }
  }

  func operationsAreIdle() -> Bool {
    queueState.withLock { !$0.isProcessing && $0.pendingOperations.isEmpty }
  }

  func waitUntilOperationsAreIdle() async {
    while !operationsAreIdle() {
      try? await Task.sleep(for: .milliseconds(20))
    }
  }
}
