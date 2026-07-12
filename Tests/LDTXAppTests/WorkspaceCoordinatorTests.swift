// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@testable import LDTX
import Foundation
import LDTXWorkspace
import os
import XCTest

@MainActor
final class WorkspaceCoordinatorTests: XCTestCase {
  func testOutputCoordinatorOwnsLifecycleTransitions() {
    let coordinator = WorkspaceOutputCoordinator()
    let initialOperationID = coordinator.operationID

    let startingOperationID = coordinator.beginStarting()
    XCTAssertEqual(coordinator.lifecycleState, .starting)
    XCTAssertEqual(coordinator.operationID, startingOperationID)
    XCTAssertNotEqual(startingOperationID, initialOperationID)

    let stoppingOperationID = coordinator.invalidateOperations(for: .stopping)
    XCTAssertEqual(coordinator.lifecycleState, .stopping)
    XCTAssertEqual(coordinator.operationID, stoppingOperationID)
    XCTAssertNotEqual(stoppingOperationID, startingOperationID)
  }

  func testOutputCoordinatorResetClearsSessionContext() {
    let coordinator = WorkspaceOutputCoordinator()
    coordinator.activeMode = .record

    coordinator.resetSession()

    XCTAssertNil(coordinator.currentSession)
    XCTAssertNil(coordinator.activeMode)
  }

  func testOutputOperationsAreSerializedWithoutChangingWorkspaceIntent() async {
    let coordinator = WorkspaceOutputCoordinator()
    let state = OSAllocatedUnfairLock(initialState: [String]())
    let completed = expectation(description: "output operations completed")

    coordinator.enqueueOperation {
      state.withLock { $0.append("stop-began") }
      try? await Task.sleep(for: .milliseconds(20))
      state.withLock { $0.append("stop-ended") }
    }
    coordinator.enqueueOperation {
      state.withLock { $0.append("start") }
      completed.fulfill()
    }

    await fulfillment(of: [completed], timeout: 1)
    XCTAssertEqual(state.withLock { $0 }, ["stop-began", "stop-ended", "start"])
  }

  func testPersistenceCoordinatorOwnsStoreAndPackageURLNormalization() throws {
    let initialStore = try WorkspaceStore(clean: WorkspaceDefinition())
    let replacementStore = try WorkspaceStore(clean: WorkspaceDefinition())
    let coordinator = WorkspacePersistenceCoordinator(store: initialStore)
    let workspaceURL = URL(fileURLWithPath: "/tmp/example")

    coordinator.replace(store: replacementStore, url: workspaceURL)

    XCTAssertTrue(coordinator.store === replacementStore)
    XCTAssertEqual(coordinator.url, workspaceURL)
    XCTAssertEqual(
      coordinator.packageURL(for: workspaceURL).pathExtension,
      WorkspacePackageLayout.pathExtension
    )
  }
}
