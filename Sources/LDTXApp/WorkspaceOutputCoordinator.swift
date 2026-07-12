// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXAppUI
import LDTXProgramRuntime
import Observation

enum OutputSessionLifecycleState {
  case idle
  case starting
  case running
  case pausing
  case readyToRestart
  case stopping
}

struct OutputSessionRestartContext {
  var outputMode: CaptureOutputMode
  var selectedYouTubeBroadcastID: String?
  var failureDescription: String
  var failedOperationID: UUID
  var restartAttempt: Int
}

@MainActor
@Observable
final class WorkspaceOutputCoordinator {
  @ObservationIgnored private let operationQueue = WorkspaceOutputOperationQueue()
  var currentSession: ProgramOutputSession?
  var lifecycleState: OutputSessionLifecycleState = .idle
  var operationID = UUID()
  var activeMode: CaptureOutputMode?
  var restartAttempt = 0

  func beginStarting() -> UUID {
    let operationID = UUID()
    self.operationID = operationID
    lifecycleState = .starting
    return operationID
  }

  func invalidateOperations(for state: OutputSessionLifecycleState) -> UUID {
    let operationID = UUID()
    self.operationID = operationID
    lifecycleState = state
    return operationID
  }

  func resetSession() {
    currentSession = nil
    activeMode = nil
  }

  func isFullyStopped() -> Bool {
    currentSession == nil && lifecycleState == .idle
  }

  func enqueueOperation(_ operation: @escaping @MainActor @Sendable () async -> Void) {
    operationQueue.enqueue(operation)
  }
}

private final class WorkspaceOutputOperationQueue: @unchecked Sendable {
  typealias Operation = @MainActor @Sendable () async -> Void

  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.workspace.output")
  private var isProcessing = false
  private var pendingOperations: [Operation] = []

  func enqueue(_ operation: @escaping Operation) {
    queue.async { [self] in
      pendingOperations.append(operation)
      processNextIfNeeded()
    }
  }

  private func processNextIfNeeded() {
    guard !isProcessing, !pendingOperations.isEmpty else { return }
    isProcessing = true
    let operation = pendingOperations.removeFirst()
    Task { @MainActor in
      await operation()
      queue.async { [self] in
        isProcessing = false
        processNextIfNeeded()
      }
    }
  }
}
