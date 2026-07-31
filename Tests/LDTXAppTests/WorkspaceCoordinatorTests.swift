// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LDTXAppUI
import LDTXDiagnostics
import LDTXWorkspace
import Testing
import os

@testable import LDTXAppCore

@MainActor
struct WorkspaceCoordinatorTests {
  @Test func dockStatusShowsRecordingThenPausedAcrossWorkspaces() {
    var appliedLabels: [String?] = []
    let controller = RecordingDockStatusController { appliedLabels.append($0) }
    let firstWorkspaceID = UUID()
    let secondWorkspaceID = UUID()

    controller.setStatus(.paused, for: firstWorkspaceID)
    controller.setStatus(.recording, for: secondWorkspaceID)
    controller.setStatus(nil, for: secondWorkspaceID)
    controller.setStatus(nil, for: firstWorkspaceID)

    #expect(appliedLabels == ["PAUSE", "REC", "PAUSE", nil])
  }

  @Test func workspaceCommandsFollowTheKeyWorkspace() {
    let coordinator = WorkspaceCommandCoordinator()
    var savedWorkspaceIDs: [Int] = []
    var reloadedWorkspaceIDs: [Int] = []
    let firstWorkspaceID = UUID()
    let secondWorkspaceID = UUID()
    coordinator.register(
      workspaceID: firstWorkspaceID,
      actions: WorkspaceActions(
        saveWorkspace: { savedWorkspaceIDs.append(1) },
        saveWorkspaceAs: {},
        reloadWorkspace: { reloadedWorkspaceIDs.append(1) },
        canReloadWorkspace: true))
    coordinator.register(
      workspaceID: secondWorkspaceID,
      actions: WorkspaceActions(
        saveWorkspace: { savedWorkspaceIDs.append(2) },
        saveWorkspaceAs: {},
        reloadWorkspace: { reloadedWorkspaceIDs.append(2) },
        canReloadWorkspace: false))

    coordinator.activate(workspaceID: secondWorkspaceID)
    #expect(coordinator.activeActions?.canReloadWorkspace == false)
    coordinator.activeActions?.saveWorkspace()
    coordinator.activeActions?.reloadWorkspace()
    coordinator.unregister(workspaceID: secondWorkspaceID)
    #expect(coordinator.activeActions?.canReloadWorkspace == true)
    coordinator.activeActions?.saveWorkspace()
    coordinator.activeActions?.reloadWorkspace()
    coordinator.unregister(workspaceID: firstWorkspaceID)

    #expect(savedWorkspaceIDs == [2, 1])
    #expect(reloadedWorkspaceIDs == [2, 1])
    #expect(coordinator.activeActions == nil)
  }

  @Test func applicationDelegateRoutesFilesExclusivelyByExtension() {
    let applicationDelegate = LDTXApplicationDelegate()
    let applicationRouter = applicationDelegate.applicationRouter
    let recordingURL = URL(fileURLWithPath: "/tmp/Example.ldtxrecord")
    let workspaceURL = URL(fileURLWithPath: "/tmp/Example.ldtxworkspace")
    let unrelatedURL = URL(fileURLWithPath: "/tmp/Example.txt")

    applicationDelegate.application(
      NSApplication.shared,
      open: [recordingURL, workspaceURL, unrelatedURL]
    )

    #expect(
      applicationRouter.recordingOpenCoordinator.takePendingRecordingURLs() == [recordingURL])
    #expect(applicationRouter.recordingOpenCoordinator.takePendingRecordingURLs().isEmpty)
    #expect(applicationRouter.workspaceOpenCoordinator.takeNextWorkspaceURL() == workspaceURL)
    #expect(applicationRouter.workspaceOpenCoordinator.takeNextWorkspaceURL() == nil)
  }

  @Test func installedFileHandlersContinueRoutingAfterLauncherCloses() {
    let applicationDelegate = LDTXApplicationDelegate()
    let applicationRouter = applicationDelegate.applicationRouter
    let recordingURL = URL(fileURLWithPath: "/tmp/Later.ldtxrecord")
    let workspaceURL = URL(fileURLWithPath: "/tmp/Later.ldtxworkspace")
    var openedRecordingURLs: [URL] = []
    var openedWorkspaceURLs: [URL] = []

    applicationRouter.recordingOpenCoordinator.installOpenHandler {
      openedRecordingURLs.append($0)
    }
    applicationRouter.workspaceOpenCoordinator.installOpenHandler {
      openedWorkspaceURLs.append($0)
    }
    applicationDelegate.application(NSApplication.shared, open: [recordingURL, workspaceURL])

    #expect(openedRecordingURLs == [recordingURL])
    #expect(openedWorkspaceURLs == [workspaceURL])
    #expect(applicationRouter.recordingOpenCoordinator.takePendingRecordingURLs().isEmpty)
    #expect(applicationRouter.workspaceOpenCoordinator.takeNextWorkspaceURL() == nil)
  }

  @Test func applicationReopenRequestsLauncherWhenNoWindowIsVisible() {
    let applicationDelegate = LDTXApplicationDelegate()
    let applicationRouter = applicationDelegate.applicationRouter
    var launcherOpenCount = 0
    applicationRouter.launcherOpenCoordinator.installOpenHandler {
      launcherOpenCount += 1
    }

    _ = applicationDelegate.applicationShouldHandleReopen(
      NSApplication.shared,
      hasVisibleWindows: true
    )
    #expect(launcherOpenCount == 0)

    _ = applicationDelegate.applicationShouldHandleReopen(
      NSApplication.shared,
      hasVisibleWindows: false
    )
    #expect(launcherOpenCount == 1)
  }

  @Test func workspaceLockIsCreatedExclusivelyWithPIDAndUTCTimestamp() throws {
    let packageURL = temporaryWorkspacePackageURL()
    defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
    let date = try #require(ISO8601DateFormatter().date(from: "2026-07-19T04:32:18Z"))
    let service = WorkspaceLockService(processIdentifier: 4821, now: { date })

    let lock = try service.acquire(at: packageURL, createsPackageDirectory: true)
    defer { service.release(lock) }
    let contents = try String(contentsOf: lock.url, encoding: .utf8)

    #expect(contents == "4821\n2026-07-19T04:32:18Z\n")
    #expect(throws: WorkspaceLockError.self) {
      try service.acquire(at: packageURL)
    }
  }

  @Test func workspaceLockReleaseAllowsReacquisition() throws {
    let packageURL = temporaryWorkspacePackageURL()
    defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
    let service = WorkspaceLockService(processIdentifier: 4821)
    let first = try service.acquire(at: packageURL, createsPackageDirectory: true)

    #expect(throws: WorkspaceLockError.self) {
      try service.acquire(at: packageURL)
    }
    service.release(first)

    let second = try service.acquire(at: packageURL)
    service.release(second)
    #expect(FileManager.default.fileExists(atPath: second.url.path))
  }

  @Test func workspaceLockConflictPreservesOwnerMetadata() throws {
    let packageURL = temporaryWorkspacePackageURL()
    defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
    let date = try #require(ISO8601DateFormatter().date(from: "2026-07-19T04:32:18Z"))
    let owner = WorkspaceLockService(processIdentifier: 4821, now: { date })
    let contender = WorkspaceLockService(processIdentifier: 9134)
    let lock = try owner.acquire(at: packageURL, createsPackageDirectory: true)
    defer { owner.release(lock) }

    do {
      _ = try contender.acquire(at: packageURL)
      Issue.record("A second Workspace unexpectedly acquired the active lock.")
    } catch WorkspaceLockError.alreadyLocked(let conflict) {
      #expect(conflict.processIdentifier == "4821")
      #expect(conflict.comments == "2026-07-19T04:32:18Z")
    }
    #expect(
      try String(contentsOf: lock.url, encoding: .utf8)
        == "4821\n2026-07-19T04:32:18Z\n")
  }

  @Test func workspaceLockReacquisitionRewritesPersistentMetadata() throws {
    let packageURL = temporaryWorkspacePackageURL()
    defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
    let firstDate = try #require(ISO8601DateFormatter().date(from: "2026-07-19T04:32:18Z"))
    let secondDate = try #require(ISO8601DateFormatter().date(from: "2026-07-20T01:02:03Z"))
    let firstService = WorkspaceLockService(processIdentifier: 4821, now: { firstDate })
    let secondService = WorkspaceLockService(processIdentifier: 9134, now: { secondDate })
    let first = try firstService.acquire(at: packageURL, createsPackageDirectory: true)
    let lockURL = first.url
    firstService.release(first)

    let second = try secondService.acquire(at: packageURL)
    defer { secondService.release(second) }

    #expect(second.url == lockURL)
    #expect(
      try String(contentsOf: second.url, encoding: .utf8)
        == "9134\n2026-07-20T01:02:03Z\n")
  }

  @Test func workspaceLockIsOutsideThePackageReplacementBoundary() throws {
    let packageURL = temporaryWorkspacePackageURL()
    defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
    let owner = WorkspaceLockService(processIdentifier: 4821)
    let contender = WorkspaceLockService(processIdentifier: 9134)
    let lock = try owner.acquire(at: packageURL, createsPackageDirectory: true)
    defer { owner.release(lock) }

    let store = try WorkspaceStore(clean: WorkspaceDefinition(name: "Locked"))
    try WorkspacePackageService().saveWorkspaceStore(store, to: packageURL)

    #expect(lock.url.deletingLastPathComponent() == packageURL.deletingLastPathComponent())
    #expect(throws: WorkspaceLockError.self) {
      try contender.acquire(at: packageURL)
    }
  }

  @Test func workspaceLockCanonicalizesWorkspaceSymlinks() throws {
    let packageURL = temporaryWorkspacePackageURL()
    let linkURL = packageURL.deletingLastPathComponent()
      .appendingPathComponent("WorkspaceLink")
      .appendingPathExtension(WorkspacePackageLayout.pathExtension)
    defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: packageURL)

    let owner = WorkspaceLockService(processIdentifier: 4821)
    let contender = WorkspaceLockService(processIdentifier: 9134)
    let lock = try owner.acquire(at: packageURL)
    defer { owner.release(lock) }

    #expect(lock.url == owner.lockURL(for: linkURL))
    #expect(throws: WorkspaceLockError.self) {
      try contender.acquire(at: linkURL)
    }
  }

  @Test func outputCoordinatorOwnsLifecycleTransitions() {
    var beginCount = 0
    var endCount = 0
    let activity = NSObject()
    let sleepInhibitor = OutputSleepInhibitor(
      beginActivity: {
        beginCount += 1
        return activity
      },
      endActivity: { token in
        #expect(token === activity)
        endCount += 1
      })
    let coordinator = WorkspaceOutputCoordinator(sleepInhibitor: sleepInhibitor)
    let initialOperationID = coordinator.operationID

    let startingOperationID = coordinator.beginStarting()
    #expect(coordinator.lifecycleState == .starting)
    #expect(coordinator.operationID == startingOperationID)
    #expect(startingOperationID != initialOperationID)
    #expect(beginCount == 1)

    _ = coordinator.beginStarting()
    #expect(beginCount == 1)

    let stoppingOperationID = coordinator.invalidateOperations(for: .stopping)
    #expect(coordinator.lifecycleState == .stopping)
    #expect(coordinator.operationID == stoppingOperationID)
    #expect(stoppingOperationID != startingOperationID)

    coordinator.resetSession()
    #expect(endCount == 1)
    coordinator.resetSession()
    #expect(endCount == 1)

    _ = coordinator.beginStarting()
    coordinator.lifecycleState = .readyToRestart
    #expect(beginCount == 2)
    #expect(endCount == 2)
  }

  @Test func outputCoordinatorResetClearsSessionContext() {
    let coordinator = WorkspaceOutputCoordinator()
    coordinator.activeMode = .record

    coordinator.resetSession()

    #expect(coordinator.currentSession == nil)
    #expect(coordinator.activeMode == nil)
  }

  @Test func outputOperationsAreSerializedWithoutChangingWorkspaceIntent() async {
    let coordinator = WorkspaceEventCoordinator(logger: .disabled)
    let state = OSAllocatedUnfairLock(initialState: [String]())
    coordinator.enqueue { _ in
      state.withLock { $0.append("stop-began") }
      try? await Task.sleep(for: .milliseconds(20))
      state.withLock { $0.append("stop-ended") }
    }
    #expect(coordinator.isLocked)
    await withCheckedContinuation { continuation in
      coordinator.enqueue { _ in
        state.withLock { $0.append("start") }
        continuation.resume()
      }
    }
    #expect(state.withLock { $0 } == ["stop-began", "stop-ended", "start"])
    try? await Task.sleep(for: .milliseconds(250))
    #expect(!coordinator.isLocked)
  }

  @Test func eachOutputOperationSettlesBeforeTheNextTransitionBegins() async {
    let eventCoordinator = WorkspaceEventCoordinator(logger: .disabled)
    let outputCoordinator = WorkspaceOutputCoordinator()
    let observedStates = OSAllocatedUnfairLock(initialState: [OutputSessionControlState]())

    eventCoordinator.enqueue { _ in
      _ = outputCoordinator.beginStarting()
      try? await Task.sleep(for: .milliseconds(20))
      outputCoordinator.lifecycleState = .running
    }
    eventCoordinator.enqueue { _ in
      let stateAtEntry = outputCoordinator.lifecycleState
      observedStates.withLock { $0.append(stateAtEntry) }
      _ = outputCoordinator.invalidateOperations(for: .stopping)
      try? await Task.sleep(for: .milliseconds(20))
      outputCoordinator.lifecycleState = .idle
    }
    await withCheckedContinuation { continuation in
      eventCoordinator.enqueue { _ in
        let stateAtEntry = outputCoordinator.lifecycleState
        observedStates.withLock { $0.append(stateAtEntry) }
        continuation.resume()
      }
    }

    #expect(observedStates.withLock { $0 } == [.running, .idle])
  }

  @Test func persistenceCoordinatorOwnsStoreAndPackageURLNormalization() throws {
    let initialStore = try WorkspaceStore(clean: WorkspaceDefinition())
    let replacementStore = try WorkspaceStore(clean: WorkspaceDefinition())
    let coordinator = WorkspacePersistenceCoordinator(store: initialStore)
    let workspaceURL = URL(fileURLWithPath: "/tmp/example")

    coordinator.replace(store: replacementStore, url: workspaceURL)

    #expect(coordinator.store === replacementStore)
    #expect(coordinator.url == workspaceURL)
    #expect(
      coordinator.packageURL(for: workspaceURL).pathExtension
        == WorkspacePackageLayout.pathExtension)
  }

  private func temporaryWorkspacePackageURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("LDTXWorkspaceLockTests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("Test.ldtxworkspace", isDirectory: true)
  }
}
