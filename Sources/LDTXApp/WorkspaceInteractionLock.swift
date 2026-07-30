// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXConcurrency
import Observation

private final class WorkspaceInteractionLockCore: @unchecked Sendable {
  let gate = LDTXReferenceCountedGate()
}

/// Projects a process-wide atomic operation count into Workspace UI state.
///
/// The C++ gate is the source of truth and may be entered from any executor.
/// Swift only owns the asynchronous operation scope and the MainActor UI projection.
@MainActor
@Observable
final class WorkspaceInteractionLock {
  @ObservationIgnored nonisolated private let core = WorkspaceInteractionLockCore()
  private(set) var isLocked = false

  /// Starts a scoped operation after synchronously projecting the locked state.
  /// The operation owns no release handle; this type always leaves the gate.
  func startPerformingWhileLocked(
    _ operation: @escaping @Sendable () async -> Void
  ) {
    core.gate.enter()
    refreshProjection()
    Task { [self] in
      await operation()
      core.gate.leave()
      refreshProjection()
    }
  }

  nonisolated func performWhileLocked<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
  ) async rethrows -> T {
    core.gate.enter()
    await refreshProjection()
    do {
      let result = try await operation()
      core.gate.leave()
      await refreshProjection()
      return result
    } catch {
      core.gate.leave()
      await refreshProjection()
      throw error
    }
  }

  nonisolated var operationCount: UInt32 {
    core.gate.count()
  }

  private func refreshProjection() {
    // Read after reaching MainActor so reordered notification tasks cannot publish stale state.
    isLocked = core.gate.isClosed()
  }
}
