// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXAutomation
import LDTXWorkspace
import Testing
import os

@testable import LDTX

@MainActor
struct WorkspaceCoordinatorTests {
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
}
