// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@testable import LDTX
import Foundation
import os
import XCTest

@MainActor
final class WorkspaceShutdownCoordinatorTests: XCTestCase {
  func testShutdownCanBeginOnlyOnceAndBlocksNewResourceStarts() async {
    let coordinator = WorkspaceShutdownCoordinator()
    let completed = expectation(description: "shutdown completed")

    XCTAssertTrue(coordinator.shouldAllowResourceStart())
    XCTAssertTrue(coordinator.beginShutdown({}, verifyStopped: { true }, completion: {
      completed.fulfill()
    }))
    XCTAssertFalse(coordinator.beginShutdown({}, verifyStopped: { true }))
    XCTAssertFalse(coordinator.shouldAllowResourceStart())
    XCTAssertFalse(coordinator.requestStart {})
    await fulfillment(of: [completed], timeout: 1)
  }

  func testFullStopIsReportedOnlyAfterEveryResourceVerifiesStopped() async {
    let coordinator = WorkspaceShutdownCoordinator()
    let resourceStopped = OSAllocatedUnfairLock(initialState: false)
    let stopCount = OSAllocatedUnfairLock(initialState: 0)

    XCTAssertTrue(coordinator.beginShutdown({
      stopCount.withLock { $0 += 1 }
    }, verifyStopped: {
      resourceStopped.withLock { $0 }
    }))
    try? await Task.sleep(for: .milliseconds(20))
    XCTAssertFalse(coordinator.resourcesAreFullyStopped())

    resourceStopped.withLock { $0 = true }
    for _ in 0..<20 where !coordinator.resourcesAreFullyStopped() {
      try? await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertTrue(coordinator.resourcesAreFullyStopped())
    XCTAssertEqual(stopCount.withLock { $0 }, 1)
    XCTAssertFalse(coordinator.shouldAllowResourceStart())
  }

  func testAcceptedStartRequestIsEnqueuedBeforeShutdownAndLaterStartsAreRejected() async {
    let coordinator = WorkspaceShutdownCoordinator()
    let events = OSAllocatedUnfairLock(initialState: [String]())
    let completed = expectation(description: "shutdown completed")

    XCTAssertTrue(coordinator.requestStart {
      events.withLock { $0.append("start-began") }
      try? await Task.sleep(for: .milliseconds(20))
      events.withLock { $0.append("start-ended") }
    })
    XCTAssertTrue(coordinator.beginShutdown({
      events.withLock { $0.append("stop") }
    }, verifyStopped: {
      true
    }, completion: {
      completed.fulfill()
    }))
    XCTAssertFalse(coordinator.requestStart {
      events.withLock { $0.append("late-start") }
    })

    await fulfillment(of: [completed], timeout: 1)
    XCTAssertEqual(events.withLock { $0 }, ["start-began", "start-ended", "stop"])
  }

  func testIdleSnapshotDoesNotBecomeTrueUntilAcceptedOperationCompletes() async {
    let coordinator = WorkspaceShutdownCoordinator()
    let operationMayFinish = OSAllocatedUnfairLock(initialState: false)

    XCTAssertTrue(coordinator.requestStart {
      while !operationMayFinish.withLock({ $0 }) {
        try? await Task.sleep(for: .milliseconds(10))
      }
    })
    XCTAssertFalse(coordinator.operationsAreIdle())

    operationMayFinish.withLock { $0 = true }
    await coordinator.waitUntilOperationsAreIdle()

    XCTAssertTrue(coordinator.operationsAreIdle())
  }
}
