// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletModel
@testable import LDTXWorkspaceAppletService
import Testing

@Suite
@MainActor
struct WorkspaceCommandQueueIntegrationTestSuite {
  private let cause = NSError(domain: "command-test", code: 42)

  @Test func validatesBeforeCreatingAQueueItemWithoutStallOrRetryIncrement() async {
    var executed = false
    var repaired = false
    var validations = 0
    let queue = WorkspaceCommandQueue(label: "test.preflight") { _, _ in }
    let outcome = await queue.submit(
      .switchProgram,
      validate: {
        validations += 1
        throw cause
      },
      reconcile: { repaired = true }, operation: { executed = true })
    guard case .rejected = outcome else {
      Issue.record("Invalid input must be rejected")
      return
    }
    #expect(validations == 1)
    #expect(!executed)
    #expect(!repaired)
    #expect(queue.pendingCommandCount == 0)
    #expect(!queue.isStalled)
    #expect(queue.retryNumber == 0)
    guard case .succeeded = await queue.submit(.switchProgram, operation: {}) else {
      Issue.record("Validation failure must not stall valid work")
      return
    }
  }

  @Test func explicitResumeAcceptsNewItemsWithoutReplayingInvalidatedWork() async throws {
    let entered = TaskQueueAsyncSignal()
    let fail = TaskQueueAsyncSignal()
    var oldPendingRan = false
    var newRan = 0
    var failedExecutions = 0
    let queue = WorkspaceCommandQueue(label: "test.new-items") { _, _ in }
    let running = Task {
      await queue.submit(.switchProgram) {
        failedExecutions += 1
        entered.signal()
        await fail.wait()
        throw cause
      }
    }
    await entered.wait()
    let discarded = Task { await queue.submit(.switchProgram) { oldPendingRan = true } }
    for _ in 0..<1_000 where queue.pendingCommandCount != 2 { await Task.yield() }
    try #require(queue.pendingCommandCount == 2)
    fail.signal()
    _ = await running.value
    guard case .rejected = await discarded.value else {
      Issue.record("Expected discarded item")
      return
    }
    #expect(queue.retryNumber == 1)
    for _ in 0..<10 { await Task.yield() }
    #expect(failedExecutions == 1)
    async let firstResume: Void = queue.resumeForNewRequests()
    async let secondResume: Void = queue.resumeForNewRequests()
    _ = await (firstResume, secondResume)
    #expect(!queue.isStalled)
    #expect(queue.retryNumber == 1)
    guard case .succeeded = await queue.submit(.switchProgram, operation: { newRan += 1 }) else {
      Issue.record("Expected a new successful item")
      return
    }
    #expect(!oldPendingRan)
    #expect(newRan == 1)
    #expect(failedExecutions == 1)
    _ = await queue.submit(.switchProgram) { throw cause }
    #expect(queue.retryNumber == 2)
    _ = await queue.submit(.switchProgram) { oldPendingRan = true }
    #expect(queue.retryNumber == 2)
    #expect(!oldPendingRan)
  }

  @Test(.timeLimit(.minutes(1)))
  func normalFailureRepairsBeforeStallAndReportsOneAggregateWithoutRunningSuccessors() async throws
  {
    let entered = TaskQueueAsyncSignal()
    let fail = TaskQueueAsyncSignal()
    let repairEntered = TaskQueueAsyncSignal()
    let finishRepair = TaskQueueAsyncSignal()
    var repaired: [WorkspaceTransactionalCommand] = []
    var reportCount = 0
    var notificationBatches: [[WorkspaceCommandFailureNotification]] = []
    var ranSuccessor = false
    weak var observedQueue: WorkspaceCommandQueue?
    let queue = WorkspaceCommandQueue(label: "test.normal-recovery") { notifications, _ in
      reportCount += 1
      notificationBatches.append(notifications)
      #expect(repaired.count == 3)
      #expect(observedQueue?.isStalled == true)
      #expect(observedQueue?.isRecovering == false)
      #expect(observedQueue?.retryNumber == 1)
    }
    observedQueue = queue
    let running = Task {
      await queue.submit(
        .reconstructRuntime,
        reconcile: {
          repairEntered.signal()
          await finishRepair.wait()
          repaired.append(.reconstructRuntime)
        }
      ) {
        entered.signal()
        await fail.wait()
        throw cause
      }
    }
    await entered.wait()
    let second = Task {
      await queue.submit(
        .switchProgram, reconcile: { repaired.append(.switchProgram) },
        operation: { ranSuccessor = true })
    }
    let third = Task {
      await queue.submit(
        .closeWorkspace, reconcile: { repaired.append(.closeWorkspace) },
        operation: { ranSuccessor = true })
    }
    for _ in 0..<1_000 where queue.pendingCommandCount != 3 { await Task.yield() }
    try #require(queue.pendingCommandCount == 3)
    fail.signal()
    await repairEntered.wait()
    #expect(queue.isRecovering)
    #expect(!queue.isStalled)
    #expect(queue.retryNumber == 0)
    #expect(reportCount == 0)
    #expect(!ranSuccessor)
    // This request arrives during repair and cannot be admitted or executed.
    let duringRepair = Task { await queue.submit(.startOutputSession) { ranSuccessor = true } }
    await Task.yield()
    #expect(queue.pendingCommandCount == 0)
    #expect(reportCount == 0)
    let newAdmission = Task {
      while queue.isRecovering { await Task.yield() }
      await queue.resumeForNewRequests()
    }
    finishRepair.signal()
    guard case .failed = await running.value,
      case .rejected = await second.value, case .rejected = await third.value
    else {
      Issue.record("Every accepted request must receive its terminal result")
      return
    }
    #expect(!queue.isRecovering)
    // The original batch is one callback; the later unadmitted request has its
    // own rejection after recovery and Stall have finished.
    guard case .rejected = await duringRepair.value else {
      Issue.record("Requests waiting through recovery must not run")
      return
    }
    #expect(!ranSuccessor)
    #expect(reportCount == 2)
    #expect(notificationBatches[0].count == 3)
    #expect(notificationBatches[1].map(\.command) == [.startOutputSession])
    await newAdmission.value
    #expect(!queue.isStalled)
    #expect(queue.retryNumber == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func pendingStopWaitsForRepairAndJoinsOneAggregateWithEveryResult() async throws {
    let entered = TaskQueueAsyncSignal()
    let fail = TaskQueueAsyncSignal()
    let cleanupEntered = TaskQueueAsyncSignal()
    let finishCleanup = TaskQueueAsyncSignal()
    var notifications: [WorkspaceCommandFailureNotification] = []
    var reconciled: [WorkspaceTransactionalCommand] = []
    var executedPending = false
    var reportCount = 0
    let queue = WorkspaceCommandQueue(label: "test.command-failure") { notification, error in
      notifications.append(contentsOf: notification)
      reportCount += 1
      #expect(reconciled.count == 6)
      #expect(error.code == 42)
    }
    let running = Task {
      await queue.submit(
        .reconstructRuntime,
        reconcile: {
          cleanupEntered.signal()
          await finishCleanup.wait()
          reconciled.append(.reconstructRuntime)
        }
      ) {
        entered.signal()
        await fail.wait()
        throw cause
      }
    }
    await entered.wait()
    let commands: [WorkspaceTransactionalCommand] = [
      .updateDeviceAssignment, .switchProgram, .startOutputSession, .closeWorkspace,
      .stopOutputSession,
    ]
    var pending: [Task<WorkspaceCommandQueue.Outcome, Never>] = []
    for command in commands {
      pending.append(
        Task {
          await queue.submit(command, reconcile: { reconciled.append(command) }) {
            executedPending = true
          }
        })
    }
    for _ in 0..<1_000 where queue.pendingCommandCount != 6 { await Task.yield() }
    try #require(queue.pendingCommandCount == 6)
    fail.signal()
    await cleanupEntered.wait()
    #expect(queue.isRecovering)
    #expect(!queue.isStalled)
    #expect(notifications.isEmpty)
    #expect(!executedPending)
    #expect(reconciled.isEmpty)
    finishCleanup.signal()
    guard case .failed(let error) = await running.value else {
      Issue.record("Running command must fail")
      return
    }
    #expect(error.code == 42)
    for task in pending {
      guard case .rejected(let error) = await task.value else {
        Issue.record("Invalidated command must be rejected")
        continue
      }
      #expect(error.code == 42)
    }
    #expect(Set(reconciled) == Set(WorkspaceTransactionalCommand.allCases))
    #expect(reconciled.count == 6)
    #expect(notifications.count == 6)
    #expect(queue.retryNumber == 1)
    #expect(reportCount == 1)
    #expect(notifications.contains { $0.dialog == .stopFailed })
    #expect(notifications.contains { $0.dialog == .closeFailed })
  }

  @Test(.timeLimit(.minutes(1)))
  func stalledQueueRejectsReapplicationAndDoesNotBlockAnotherWorkspace() async {
    var reported: [WorkspaceCommandFailureNotification] = []
    var rejectedReconciled = false
    var ranRetry = false
    let first = WorkspaceCommandQueue(label: "test.workspace.commands") { notification, _ in
      reported.append(contentsOf: notification)
    }
    let second = WorkspaceCommandQueue(label: "test.workspace.commands") { _, _ in
      Issue.record("Independent Workspace must not fail")
    }
    _ = await first.submit(.switchProgram) { throw cause }
    let result = await first.submit(
      .switchProgram, reconcile: { rejectedReconciled = true }, operation: { ranRetry = true })
    guard case .rejected = result else {
      Issue.record("Stall must reject new work")
      return
    }
    #expect(rejectedReconciled)
    #expect(!ranRetry)
    #expect(reported.map(\.command) == [.switchProgram, .switchProgram])
    let other = await second.submit(.switchProgram) {}
    guard case .succeeded = other else {
      Issue.record("Independent Workspace must progress")
      return
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func successWaitsForOperationBeforeStartingSuccessor() async throws {
    let entered = TaskQueueAsyncSignal()
    let release = TaskQueueAsyncSignal()
    var events: [String] = []
    let queue = WorkspaceCommandQueue(label: "test.command-fifo") { _, _ in
      Issue.record("Successful work must not report an error")
    }
    let first = Task {
      await queue.submit(.switchProgram) {
        events.append("first")
        entered.signal()
        await release.wait()
        events.append("first finished")
      }
    }
    await entered.wait()
    let second = Task { await queue.submit(.switchProgram) { events.append("second") } }
    for _ in 0..<1_000 where queue.pendingCommandCount != 2 { await Task.yield() }
    try #require(queue.pendingCommandCount == 2)
    #expect(events == ["first"])
    release.signal()
    guard case .succeeded = await first.value, case .succeeded = await second.value else {
      Issue.record("Both operations must succeed")
      return
    }
    #expect(events == ["first", "first finished", "second"])
  }
}
