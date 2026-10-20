// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXTaskQueue
import LDTXWorkspaceAppletModel

/// Result transport and failure fan-out for a Coordinator's command queue.
/// Operations must await their own resource boundary. This type deliberately
/// never restores discarded requests or retries operations automatically.
@MainActor
public final class WorkspaceCommandQueue {
  public typealias Outcome = WorkspaceCommandOutcome

  @MainActor private final class Request {
    let command: WorkspaceTransactionalCommand
    let reconcile: @MainActor () async -> Void
    let continuation: CheckedContinuation<Outcome, Never>
    var claimed = false

    init(
      command: WorkspaceTransactionalCommand, reconcile: @escaping @MainActor () async -> Void,
      continuation: CheckedContinuation<Outcome, Never>
    ) {
      self.command = command
      self.reconcile = reconcile
      self.continuation = continuation
    }
  }

  private var queue: EventTaskQueue
  private let label: String
  private var resumeTask: Task<Void, Never>?
  private let reportFailure: @MainActor ([WorkspaceCommandFailureNotification], NSError) -> Void
  private var requests: [Request] = []
  public private(set) var isStalled = false
  public private(set) var isRecovering = false
  public private(set) var retryNumber: UInt64 = 0
  private var recoveryWaiters: [CheckedContinuation<Void, Never>] = []
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  var pendingCommandCount: Int { requests.count }
  public func contains(_ command: WorkspaceTransactionalCommand) -> Bool {
    requests.contains { $0.command == command }
  }

  public init(
    label: String,
    reportFailure: @escaping @MainActor ([WorkspaceCommandFailureNotification], NSError) -> Void
  ) {
    self.label = label
    queue = EventTaskQueue(label: label)
    self.reportFailure = reportFailure
  }

  public func submit(
    _ command: WorkspaceTransactionalCommand,
    validate: @MainActor () throws -> Void = {},
    reconcile: @escaping @MainActor () async -> Void = {},
    operation: @escaping @MainActor () async throws -> Void
  ) async -> Outcome {
    let admissionRetryNumber = retryNumber
    // Requests arriving during recovery wait outside admission. They cannot
    // execute, escape the failure boundary, or imply the queue has recovered.
    if isRecovering {
      await withCheckedContinuation { recoveryWaiters.append($0) }
    }
    do {
      try validate()
    } catch {
      let cause = error as NSError
      reportFailure(WorkspaceCommandFailureNotification.stalledCommands([command]), cause)
      return .rejected(cause)
    }
    return await withCheckedContinuation { continuation in
      let request = Request(command: command, reconcile: reconcile, continuation: continuation)
      guard !isStalled, retryNumber == admissionRetryNumber else {
        reject(request)
        return
      }
      requests.append(request)
      let accepted = queue.enqueue(
        onDiscard: { Task { @MainActor in self.reject(request) } }
      ) { finish in
        { _ in
          Task { @MainActor in
            defer { finish() }
            do {
              try await operation()
              request.claimed = true
              self.requests.removeAll { $0 === request }
              request.continuation.resume(returning: .succeeded)
              self.notifyIdleIfNeeded()
            } catch {
              await self.fail(request, cause: error as NSError)
            }
          }
        }
      }
      if !accepted { reject(request) }
    }
  }

  private func fail(_ failed: Request, cause: NSError) async {
    isRecovering = true
    let affected = requests
    requests.removeAll()
    for request in affected { request.claimed = true }
    let notifications = WorkspaceCommandFailureNotification.stalledCommands(affected.map(\.command))
    // The failed entry retains its EventTaskQueue completion throughout this
    // await. Thus no successor can execute while consistency is being repaired.
    for request in affected { await request.reconcile() }

    // Wait for the underlying queue's state transition, not merely submission
    // of a Stall request, before publishing the aggregated error.
    await withCheckedContinuation { continuation in
      queue.stall { continuation.resume() }
    }
    isStalled = true
    retryNumber += 1
    isRecovering = false
    reportFailure(notifications, cause)
    for request in affected {
      request.continuation.resume(returning: request === failed ? .failed(cause) : .rejected(cause))
    }
    let waiters = recoveryWaiters
    recoveryWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    notifyIdleIfNeeded()
  }

  /// Joins admitted operations and their consistency repair. The owner closes
  /// admission through its existing lifecycle guards before calling this.
  public func waitForCurrentRequests() async {
    while !requests.isEmpty || isRecovering {
      await withCheckedContinuation { idleWaiters.append($0) }
    }
  }

  private func notifyIdleIfNeeded() {
    guard requests.isEmpty, !isRecovering else { return }
    let waiters = idleWaiters
    idleWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  /// Explicitly opens admission for new requests after joining the old queue.
  /// It retains the retry number and never transfers or replays old QueueItems.
  /// Call this for a new user request, not from failure handling or observation.
  public func resumeForNewRequests() async {
    if let resumeTask {
      await resumeTask.value
      return
    }
    guard isStalled, !isRecovering else { return }
    let previous = queue
    let task = Task { @MainActor in
      await withCheckedContinuation { continuation in
        previous.stop { continuation.resume() }
      }
      queue = EventTaskQueue(label: label)
      isStalled = false
      resumeTask = nil
    }
    resumeTask = task
    await task.value
  }

  private func reject(_ request: Request) {
    guard !request.claimed else { return }
    request.claimed = true
    requests.removeAll { $0 === request }
    let error = NSError(
      domain: "tokyo.kaito.ldtx.WorkspaceCommandQueue", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "The Workspace command queue is stalled."])
    let notification = WorkspaceCommandFailureNotification.stalledCommands([request.command])[0]
    Task { @MainActor in
      await request.reconcile()
      reportFailure([notification], error)
      request.continuation.resume(returning: .rejected(error))
    }
  }
}
