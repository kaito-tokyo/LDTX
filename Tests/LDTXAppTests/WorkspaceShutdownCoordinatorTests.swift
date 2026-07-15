// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@testable import LDTX
import Foundation
import os
import Testing

@MainActor
struct WorkspaceShutdownCoordinatorTests {
  @Test func shutdownCanBeginOnlyOnceAndBlocksNewResourceStarts() async {
    let coordinator = WorkspaceShutdownCoordinator()

    #expect(coordinator.shouldAllowResourceStart())
    await withCheckedContinuation { continuation in
      let began = coordinator.beginShutdown({}, verifyStopped: { true }, completion: {
        continuation.resume()
      })
      #expect(began)
      let beganAgain = coordinator.beginShutdown({}, verifyStopped: { true })
      #expect(!beganAgain)
      #expect(!coordinator.shouldAllowResourceStart())
      let acceptedStart = coordinator.requestStart {}
      #expect(!acceptedStart)
    }
  }

  @Test func fullStopIsReportedOnlyAfterEveryResourceVerifiesStopped() async {
    let coordinator = WorkspaceShutdownCoordinator()
    let resourceStopped = OSAllocatedUnfairLock(initialState: false)
    let stopCount = OSAllocatedUnfairLock(initialState: 0)

    let began = coordinator.beginShutdown({
      stopCount.withLock { $0 += 1 }
    }, verifyStopped: {
      resourceStopped.withLock { $0 }
    })
    #expect(began)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(!coordinator.resourcesAreFullyStopped())

    resourceStopped.withLock { $0 = true }
    for _ in 0..<20 where !coordinator.resourcesAreFullyStopped() {
      try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(coordinator.resourcesAreFullyStopped())
    #expect(stopCount.withLock { $0 } == 1)
    #expect(!coordinator.shouldAllowResourceStart())
  }

  @Test func acceptedStartRequestIsEnqueuedBeforeShutdownAndLaterStartsAreRejected() async {
    let coordinator = WorkspaceShutdownCoordinator()
    let events = OSAllocatedUnfairLock(initialState: [String]())

    await withCheckedContinuation { continuation in
      let acceptedStart = coordinator.requestStart {
        events.withLock { $0.append("start-began") }
        try? await Task.sleep(for: .milliseconds(20))
        events.withLock { $0.append("start-ended") }
      }
      #expect(acceptedStart)
      let began = coordinator.beginShutdown({
        events.withLock { $0.append("stop") }
      }, verifyStopped: {
        true
      }, completion: {
        continuation.resume()
      })
      #expect(began)
      let acceptedLateStart = coordinator.requestStart {
        events.withLock { $0.append("late-start") }
      }
      #expect(!acceptedLateStart)
    }

    #expect(events.withLock { $0 } == ["start-began", "start-ended", "stop"])
  }

  @Test func idleSnapshotDoesNotBecomeTrueUntilAcceptedOperationCompletes() async {
    let coordinator = WorkspaceShutdownCoordinator()
    let operationMayFinish = OSAllocatedUnfairLock(initialState: false)

    let accepted = coordinator.requestStart {
      while !operationMayFinish.withLock({ $0 }) {
        try? await Task.sleep(for: .milliseconds(10))
      }
    }
    #expect(accepted)
    #expect(!coordinator.operationsAreIdle())

    operationMayFinish.withLock { $0 = true }
    await coordinator.waitUntilOperationsAreIdle()

    #expect(coordinator.operationsAreIdle())
  }
}
