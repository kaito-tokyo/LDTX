// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXAppUI
import LDTXProgramRuntime
import LDTXTaskQueue
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
  @ObservationIgnored private let operationQueue = EventTaskQueue(
    label: "tokyo.kaito.ldtx.workspace.output")
  @ObservationIgnored private var operationGeneration: UInt64 = 0
  var currentSession: ActiveProgramOutputSession?
  var youtubeOutputBoundary: ProgramYouTubeOutputBoundary?
  var lifecycleState: OutputSessionLifecycleState = .idle
  var operationID = UUID()
  var activeMode: CaptureOutputMode?
  var restartAttempt = 0
  var isOperationQueueLocked = false

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

  func finishYouTubeOutputBoundary() async {
    guard let boundary = youtubeOutputBoundary else { return }
    await withCheckedContinuation { continuation in
      boundary.finish { continuation.resume() }
    }
    if youtubeOutputBoundary === boundary {
      youtubeOutputBoundary = nil
    }
  }

  func isFullyStopped() -> Bool {
    currentSession == nil && lifecycleState == .idle
  }

  func enqueueOperation(
    _ operation: @escaping @MainActor @Sendable (StopToken) async -> Void
  ) {
    let completionState = WorkspaceEventCompletion()
    operationGeneration &+= 1
    let generation = operationGeneration
    isOperationQueueLocked = true
    let accepted = operationQueue.enqueue { completion in
      { stopToken in
        Task { @MainActor in
          defer {
            completionState.finish()
            completion()
          }
          await operation(stopToken)
        }
      }
    }
    if !accepted { completionState.finish() }

    Task { @MainActor [weak self] in
      guard let self else { return }
      await completionState.wait()
      try? await Task.sleep(for: .milliseconds(200))
      guard self.operationGeneration == generation else { return }
      self.isOperationQueueLocked = false
    }
  }

  func interruptOperations() async {
    await withCheckedContinuation { continuation in
      operationQueue.stop {
        continuation.resume()
      }
    }
  }
}

@MainActor
private final class WorkspaceEventCompletion {
  private(set) var isFinished = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func finish() {
    guard !isFinished else { return }
    isFinished = true
    let waiters = waiters
    self.waiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func wait() async {
    guard !isFinished else { return }
    await withCheckedContinuation { continuation in
      if isFinished {
        continuation.resume()
      } else {
        waiters.append(continuation)
      }
    }
  }
}
