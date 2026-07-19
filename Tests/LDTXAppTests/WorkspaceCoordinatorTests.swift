// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LDTXAutomation
import LDTXWorkspace
import Testing
import os

@testable import LDTX

@MainActor
struct WorkspaceCoordinatorTests {
  @Test func unsavedWorkspaceURLsHaveOneCanonicalForm() throws {
    let url = LDTXResourceURL.unsavedWorkspace(sequence: 7)

    #expect(url.absoluteString == "ldtx://workspace/unsaved/7")
    #expect(try LDTXResourceURL.canonicalWorkspaceURL(url) == url)
    #expect(throws: LDTXResourceURLError.self) {
      try LDTXResourceURL.canonicalWorkspaceURL("ldtx://workspace/unsaved/07")
    }
    #expect(throws: LDTXResourceURLError.self) {
      try LDTXResourceURL.canonicalWorkspaceURL("ldtx://workspace/unsaved/7?name=Example")
    }
  }

  @Test func automationRouterListsAndResolvesWorkspaceURLs() throws {
    let router = AppAutomationRouter()
    let state = AppAutomationState()
    let unsavedURL = LDTXResourceURL.unsavedWorkspace(sequence: 3)

    try router.registerWorkspace(
      token: 3,
      url: unsavedURL,
      title: "New Workspace 3",
      documentURL: nil,
      state: state
    )

    #expect(try router.workspaceState(for: unsavedURL) === state)
    #expect(
      router.windowList().windows == [
        LDTXAutomationWindow(
          url: unsavedURL.absoluteString,
          kind: "workspace",
          title: "New Workspace 3"
        )
      ])

    router.unregisterWorkspace(token: 3)
    #expect(throws: AppAutomationRouterError.self) {
      try router.workspaceState(for: unsavedURL)
    }
  }

  @Test func automationRouterRejectsDuplicateFormalWorkspaceURLs() throws {
    let router = AppAutomationRouter()
    let url = URL(fileURLWithPath: "/tmp/Duplicate.ldtxworkspace")
    try router.registerWorkspace(
      token: 1, url: url, title: "First", documentURL: url, state: AppAutomationState())
    try router.registerWorkspace(
      token: 2, url: url, title: "Second", documentURL: url, state: AppAutomationState())

    #expect(throws: AppAutomationRouterError.self) {
      try router.workspaceState(for: url)
    }
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

  @Test func outputCoordinatorOwnsLifecycleTransitions() {
    let coordinator = WorkspaceOutputCoordinator()
    let initialOperationID = coordinator.operationID

    let startingOperationID = coordinator.beginStarting()
    #expect(coordinator.lifecycleState == .starting)
    #expect(coordinator.operationID == startingOperationID)
    #expect(startingOperationID != initialOperationID)

    let stoppingOperationID = coordinator.invalidateOperations(for: .stopping)
    #expect(coordinator.lifecycleState == .stopping)
    #expect(coordinator.operationID == stoppingOperationID)
    #expect(stoppingOperationID != startingOperationID)
  }

  @Test func outputCoordinatorResetClearsSessionContext() {
    let coordinator = WorkspaceOutputCoordinator()
    coordinator.activeMode = .record

    coordinator.resetSession()

    #expect(coordinator.currentSession == nil)
    #expect(coordinator.activeMode == nil)
  }

  @Test func combinedOutputFailuresAreIsolatedToTheFailedService() {
    #expect(
      WorkspaceOutputFailureDisposition.resolve(
        failedService: .record, outputMode: .youtubeAndRecord) == .stopRecordService)
    #expect(
      WorkspaceOutputFailureDisposition.resolve(
        failedService: .youtube, outputMode: .youtubeAndRecord) == .stopYouTubeService)
  }

  @Test func soleOutputServiceFailureStopsTheOutputSession() {
    #expect(
      WorkspaceOutputFailureDisposition.resolve(
        failedService: .record, outputMode: .record) == .stopAllOutput)
    #expect(
      WorkspaceOutputFailureDisposition.resolve(
        failedService: .youtube, outputMode: .youtube) == .stopAllOutput)
  }

  @Test func outputOperationsAreSerializedWithoutChangingWorkspaceIntent() async {
    let coordinator = WorkspaceOutputCoordinator()
    let state = OSAllocatedUnfairLock(initialState: [String]())
    coordinator.enqueueOperation {
      state.withLock { $0.append("stop-began") }
      try? await Task.sleep(for: .milliseconds(20))
      state.withLock { $0.append("stop-ended") }
    }
    #expect(coordinator.isOperationQueueLocked)
    await withCheckedContinuation { continuation in
      coordinator.enqueueOperation {
        state.withLock { $0.append("start") }
        continuation.resume()
      }
    }
    #expect(state.withLock { $0 } == ["stop-began", "stop-ended", "start"])
    try? await Task.sleep(for: .milliseconds(250))
    #expect(!coordinator.isOperationQueueLocked)
  }

  @Test func eachOutputOperationSettlesBeforeTheNextTransitionBegins() async {
    let coordinator = WorkspaceOutputCoordinator()
    let observedStates = OSAllocatedUnfairLock(initialState: [OutputSessionLifecycleState]())

    coordinator.enqueueOperation {
      _ = coordinator.beginStarting()
      try? await Task.sleep(for: .milliseconds(20))
      coordinator.lifecycleState = .running
    }
    coordinator.enqueueOperation {
      let stateAtEntry = coordinator.lifecycleState
      observedStates.withLock { $0.append(stateAtEntry) }
      _ = coordinator.invalidateOperations(for: .stopping)
      try? await Task.sleep(for: .milliseconds(20))
      coordinator.lifecycleState = .idle
    }
    await withCheckedContinuation { continuation in
      coordinator.enqueueOperation {
        let stateAtEntry = coordinator.lifecycleState
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

  @Test func legacyAutomationOutputModeMigratesToToggles() throws {
    var settings = Ldtx_Automation_V1_OutputSettings()
    settings.captureOutputMode = .youtubeAndRecord

    let selection = try OutputToggleSelection.resolve(
      settings,
      current: OutputToggleSelection(recordingEnabled: false, youtubeEnabled: false))
    #expect(selection == OutputToggleSelection(recordingEnabled: true, youtubeEnabled: true))
  }

  @Test func automationToggleFieldsAreCanonicalAndCanDisableBoth() throws {
    var settings = Ldtx_Automation_V1_OutputSettings()
    settings.captureOutputMode = .youtubeAndRecord
    settings.recordingEnabled = false
    settings.youtubeEnabled = false

    let selection = try OutputToggleSelection.resolve(
      settings,
      current: OutputToggleSelection(recordingEnabled: true, youtubeEnabled: true))
    #expect(selection == OutputToggleSelection(recordingEnabled: false, youtubeEnabled: false))
  }

  @Test func partialAutomationToggleUpdatePreservesUnspecifiedToggle() throws {
    var settings = Ldtx_Automation_V1_OutputSettings()
    settings.recordingEnabled = false

    let selection = try OutputToggleSelection.resolve(
      settings,
      current: OutputToggleSelection(recordingEnabled: true, youtubeEnabled: true))
    #expect(selection == OutputToggleSelection(recordingEnabled: false, youtubeEnabled: true))
  }

  @Test func toggleSelectionDistinguishesRecordOnlyFromAllDisabled() {
    let recordOnly = OutputToggleSelection(recordingEnabled: true, youtubeEnabled: false)
    let disabled = OutputToggleSelection(recordingEnabled: false, youtubeEnabled: false)
    #expect(recordOnly != disabled)
  }

  private func temporaryWorkspacePackageURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("LDTXWorkspaceLockTests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("Test.ldtxworkspace", isDirectory: true)
  }
}
