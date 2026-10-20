// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletModel
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1015: present-operation-errors", .serialized)
  @MainActor
  struct UCT1015WorkspaceAppletCoordinatorIntegrationTestSuite {
    @Test func inactiveOutputDoesNotReopenStalledAssignments() async {
      let document = WorkspaceDocument()
      let coordinator = WorkspaceAppletCoordinator(document: document)
      await Task.yield()
      await coordinator.transactionalCommands.waitForCurrentRequests()
      _ = await coordinator.transactionalCommands.submit(.updateDeviceAssignment) {
        throw CocoaError(.fileReadUnknown)
      }
      document.isOutputActive = true
      for _ in 0..<100 { await Task.yield() }
      document.isOutputActive = false
      for _ in 0..<100 { await Task.yield() }
      #expect(coordinator.transactionalCommands.isStalled)
      #expect(coordinator.transactionalCommands.retryNumber == 1)
      #expect(!coordinator.transactionalCommands.contains(.updateDeviceAssignment))
      await coordinator.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func inactiveOutputResynchronizesAssignmentsWithoutInterruptingAcceptedWork() async throws {
      let document = WorkspaceDocument()
      let coordinator = WorkspaceAppletCoordinator(document: document)
      await Task.yield()
      await coordinator.transactionalCommands.waitForCurrentRequests()
      let entered = AsyncStream<Void>.makeStream()
      var release: CheckedContinuation<Void, Never>?
      let running = Task {
        await coordinator.transactionalCommands.submit(.switchProgram) {
          await withCheckedContinuation { continuation in
            release = continuation
            entered.continuation.yield(())
            entered.continuation.finish()
          }
        }
      }
      var events = entered.stream.makeAsyncIterator()
      _ = await events.next()
      defer { release?.resume() }
      document.isOutputActive = true
      for _ in 0..<100 { await Task.yield() }
      #expect(!coordinator.transactionalCommands.contains(.updateDeviceAssignment))
      document.isOutputActive = false
      for _ in 0..<1_000 where !coordinator.transactionalCommands.contains(.updateDeviceAssignment)
      {
        await Task.yield()
      }
      #expect(coordinator.transactionalCommands.contains(.updateDeviceAssignment))
      #expect(coordinator.transactionalCommands.contains(.switchProgram))
      release?.resume()
      release = nil
      _ = await running.value
      await coordinator.transactionalCommands.waitForCurrentRequests()
      #expect(!coordinator.transactionalCommands.isStalled)
      await coordinator.shutdown()
    }

    @Test func closeRejectsStartingAndActiveOutputWithoutStall() async throws {
      let document = WorkspaceDocument()
      let coordinator = WorkspaceAppletCoordinator(document: document)
      await Task.yield()
      await coordinator.transactionalCommands.waitForCurrentRequests()
      for state: WorkspaceRecordingState in [.starting, .recording] {
        document.recordingState = state
        document.isOutputActive = true
        guard case .rejected = await coordinator.closeWorkspace() else {
          Issue.record("Close must not interrupt output")
          return
        }
        #expect(!document.isClosed)
        #expect(coordinator.transactionalCommands.retryNumber == 0)
      }
      document.isOutputActive = false
      document.recordingState = .idle
      guard case .succeeded = await coordinator.closeWorkspace() else {
        Issue.record("Stopped workspace must close")
        return
      }
      #expect(document.isClosed)
    }

    @Test func closeWaitsForAcceptedWorkWithoutBlockingAnotherWorkspace() async throws {
      let first = WorkspaceAppletCoordinator(document: WorkspaceDocument())
      let second = WorkspaceAppletCoordinator(document: WorkspaceDocument())
      await Task.yield()
      await first.transactionalCommands.waitForCurrentRequests()
      await second.transactionalCommands.waitForCurrentRequests()
      let entered = AsyncStream<Void>.makeStream()
      var release: CheckedContinuation<Void, Never>?
      let running = Task {
        await first.transactionalCommands.submit(.updateDeviceAssignment) {
          await withCheckedContinuation { continuation in
            release = continuation
            entered.continuation.yield(())
          }
        }
      }
      var events = entered.stream.makeAsyncIterator()
      _ = await events.next()
      let close = Task { await first.closeWorkspace() }
      for _ in 0..<1000 where first.transactionalCommands.pendingCommandCount != 2 {
        await Task.yield()
      }
      #expect(first.transactionalCommands.pendingCommandCount == 2)
      #expect(!first.stateService.isClosed)
      guard case .succeeded = await second.closeWorkspace() else {
        Issue.record("Workspaces must not share a shutdown barrier")
        release?.resume()
        return
      }
      #expect(!first.stateService.isClosed)
      release?.resume()
      _ = await running.value
      guard case .succeeded = await close.value else {
        Issue.record("Close failed")
        return
      }
      #expect(first.stateService.isClosed)
    }

    @Test func discardedCloseDoesNotCloseOrAutomaticallyReturn() async throws {
      let coordinator = WorkspaceAppletCoordinator(document: WorkspaceDocument())
      await Task.yield()
      await coordinator.transactionalCommands.waitForCurrentRequests()
      let entered = AsyncStream<Void>.makeStream()
      var release: CheckedContinuation<Void, Never>?
      let failed = Task {
        await coordinator.transactionalCommands.submit(.switchProgram) {
          await withCheckedContinuation { continuation in
            release = continuation
            entered.continuation.yield(())
          }
          throw NSError(domain: "close-audit", code: 7)
        }
      }
      var events = entered.stream.makeAsyncIterator()
      _ = await events.next()
      let closing = Task { await coordinator.closeWorkspace() }
      for _ in 0..<1000 where coordinator.transactionalCommands.pendingCommandCount != 2 {
        await Task.yield()
      }
      release?.resume()
      _ = await failed.value
      guard case .rejected = await closing.value else {
        Issue.record("Close must be discarded")
        return
      }
      #expect(!coordinator.stateService.isClosed)
      #expect(coordinator.transactionalCommands.retryNumber == 1)
      #expect(coordinator.stateService.operationErrors.count == 1)
      guard case .succeeded = await coordinator.closeWorkspace() else {
        Issue.record("Explicit new close failed")
        return
      }
      #expect(coordinator.stateService.isClosed)
      #expect(coordinator.transactionalCommands.retryNumber == 1)
    }

    @Test func stopDuringStartWaitsFIFOWithoutInterruptingTheTransition() async throws {
      let document = WorkspaceDocument()
      let coordinator = WorkspaceAppletCoordinator(document: document)
      await Task.yield()
      await coordinator.transactionalCommands.waitForCurrentRequests()
      let entered = AsyncStream<Void>.makeStream()
      var release: CheckedContinuation<Void, Never>?
      var stopReturned = false
      let starting = Task {
        await coordinator.transactionalCommands.submit(.startOutputSession) {
          coordinator.windowRuntime.setRecordingState(.starting)
          await withCheckedContinuation { continuation in
            release = continuation
            entered.continuation.yield(())
            entered.continuation.finish()
          }
          coordinator.windowRuntime.setRecordingState(.recording)
        }
      }
      var iterator = entered.stream.makeAsyncIterator()
      _ = await iterator.next()
      defer { release?.resume() }
      guard case .rejected = await coordinator.closeWorkspace() else {
        Issue.record("Pending Start must prevent Close admission")
        return
      }
      let stopping = Task {
        await coordinator.stopOutput()
        stopReturned = true
      }
      for _ in 0..<1_000 where coordinator.transactionalCommands.pendingCommandCount != 2 {
        await Task.yield()
      }
      try #require(coordinator.transactionalCommands.pendingCommandCount == 2)
      #expect(coordinator.windowRuntime.recordingState == .starting)
      #expect(!stopReturned)
      release?.resume()
      release = nil
      _ = await starting.value
      await stopping.value
      #expect(coordinator.windowRuntime.recordingState == .idle)
      #expect(coordinator.transactionalCommands.retryNumber == 0)
      await coordinator.shutdown()
    }

    @Test func unavailableAssignmentCompletesWithoutStallAndActiveOutputRejectsBeforeEnqueue()
      async throws
    {
      let suite = "assignment-result-\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let data = WorkspaceAppletData(userDefaults: defaults)
      data.setPhysicalDeviceID(.avCaptureDevice(uniqueID: "unavailable-camera"), for: 1)
      let document = WorkspaceDocument(
        definition: .with {
          $0.videoComponents = [.with { $0.vfxSource = .with { $0.internalID = 1 } }]
        }, preferences: .init())
      let coordinator = WorkspaceAppletCoordinator(document: document, appletData: data)
      try coordinator.persistenceCoordinator.adoptRuntimeWorkspace(document.editingWorkspace)
      guard
        case .succeeded = await (try coordinator.updateDeviceAssignments(availableCameraIDs: []))
          .value
      else {
        Issue.record("Unavailable input is not an execution failure")
        return
      }
      #expect(!coordinator.transactionalCommands.isStalled)
      #expect(coordinator.transactionalCommands.retryNumber == 0)
      document.isOutputActive = true
      #expect(throws: (any Error).self) {
        try coordinator.updateDeviceAssignments(availableCameraIDs: [])
      }
      #expect(coordinator.transactionalCommands.retryNumber == 0)
      document.isOutputActive = false
      await coordinator.shutdown()
    }

    @Test func explicitSavedReconstructionResumesOnlyForNewUserRequest() async throws {
      let document = WorkspaceDocument()
      let coordinator = WorkspaceAppletCoordinator(document: document)
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("ldtxworkspace")
      defer { try? FileManager.default.removeItem(at: url) }
      try WorkspaceBundleWriterV4().write(document.editingWorkspace, to: url)
      await coordinator.refreshPersistedWorkspace(at: url) { true }
      _ = await coordinator.transactionalCommands.submit(.switchProgram) {
        throw NSError(domain: "test-stall", code: 95)
      }
      await coordinator.refreshPersistedWorkspace(at: url) { true }
      #expect(coordinator.transactionalCommands.isStalled)
      #expect(coordinator.transactionalCommands.retryNumber == 1)
      await coordinator.refreshPersistedWorkspace(at: url, userInitiated: true) { true }
      #expect(!coordinator.transactionalCommands.isStalled)
      #expect(coordinator.transactionalCommands.retryNumber == 1)
      await coordinator.shutdown()
    }

    @Test(arguments: [false, true])
    func explicitSaveCallbackRunsOnlyAfterSuccessfulNativeSave(success: Bool) async {
      let document = SaveResultDocument(success: success)
      var applied = false
      WorkspaceDocumentCloseCoordinator.save(document, onSuccess: { applied = true })
      await WorkspaceDocumentCloseCoordinator.waitForSaves()
      #expect(applied == success)
      document.close()
    }

    @Test func explicitProgramReapplyUsesNewItemAndStallSequence() async throws {
      let document = WorkspaceDocument(
        definition: .with { $0.programs = [.with { $0.internalID = 1 }] }, preferences: .init())
      let coordinator = WorkspaceAppletCoordinator(document: document)
      let original = coordinator.programSelectionState
      var failedExecutions = 0
      _ = await coordinator.transactionalCommands.submit(.switchProgram) {
        failedExecutions += 1
        throw NSError(domain: "test", code: 88)
      }
      #expect(coordinator.programSelectionState.value == original.value)
      #expect(coordinator.programSelectionState.retryNumber == 1)
      #expect(coordinator.programSelectionState != original)
      guard case .succeeded = await (try coordinator.selectProgram(internalID: 1)).value else {
        Issue.record("Explicit reapplication must create new work")
        return
      }
      #expect(failedExecutions == 1)
      #expect(coordinator.programSelectionState.retryNumber == 1)
      #expect(!coordinator.transactionalCommands.isStalled)
      await coordinator.shutdown()
    }
    @Test func captureCompletionFollowsFailureStatusPublication() async throws {
      let suite = "capture-completion-\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let data = WorkspaceAppletData(userDefaults: defaults)
      data.setPhysicalDeviceID(.avCaptureDevice(uniqueID: "unavailable-camera"), for: 1)
      let document = WorkspaceDocument(
        definition: .with {
          $0.videoComponents = [
            .with {
              $0.vfxSource = .with {
                $0.internalID = 1
                $0.displayName = "Missing camera"
              }
            }
          ]
        }, preferences: .init())
      let coordinator = WorkspaceAppletCoordinator(document: document, appletData: data)
      try coordinator.persistenceCoordinator.adoptRuntimeWorkspace(document.editingWorkspace)
      await Task.yield()
      await coordinator.transactionalCommands.waitForCurrentRequests()
      coordinator.updateCaptureFailures([])
      document.operationErrors.removeAll()
      await withCheckedContinuation { continuation in
        coordinator.synchronizeCaptureInputs(availableCameraIDs: []) { failures in
          MainActor.assumeIsolated {
            #expect(failures == ["unavailable-camera"])
            #expect(document.operationErrors.isEmpty)
            #expect(!coordinator.transactionalCommands.isStalled)
          }
          continuation.resume()
        }
      }
      await coordinator.shutdown()
    }

    @Test func commandQueuePublishesRetryGuidanceWithoutEditingDocument() async {
      let document = WorkspaceDocument()
      let coordinator = WorkspaceAppletCoordinator(document: document)
      let baseline = document.editingWorkspace
      let result = await coordinator.transactionalCommands.submit(.reconstructRuntime) {
        throw NSError(
          domain: "test-command", code: 51,
          userInfo: [NSLocalizedDescriptionKey: "Resource application failed."])
      }
      guard case .failed = result else {
        Issue.record("Expected failed command")
        return
      }
      #expect(document.editingWorkspace == baseline)
      #expect(document.operationErrors.count == 1)
      #expect(document.operationErrors.first?.localizedRecoverySuggestion?.contains("save") == true)
      await coordinator.shutdown()
    }

    @Test func failedSelectionPreservesDocumentAndAllowsExplicitReapplication() async throws {
      let document = WorkspaceDocument(
        definition: .with { $0.programs = [.with { $0.internalID = 1 }] }, preferences: .init())
      let coordinator = WorkspaceAppletCoordinator(document: document)
      let baseline = document.editingWorkspace
      do {
        _ = await (try coordinator.selectProgram(internalID: .max)).value
        Issue.record("Expected missing Program")
      } catch {
        #expect(
          (error as NSError).localizedRecoverySuggestion?.contains("select the Program again")
            == true)
      }
      #expect(document.editingWorkspace == baseline)
      try coordinator.persistenceCoordinator.adoptRuntimeWorkspace(document.editingWorkspace)
      document.editWorkspace(undoManager: nil) {
        $0.preferences.landscapeProgramPreferences[1, default: .init()].videoLayerInternalIds = [
          999
        ]
      }
      #expect(throws: (any Error).self) { try coordinator.selectProgram(internalID: 1) }
      #expect(coordinator.transactionalCommands.retryNumber == 0)
      #expect(!coordinator.transactionalCommands.isStalled)
      document.editWorkspace(undoManager: nil) { $0.preferences = baseline.preferences }
      do {
        _ = await (try coordinator.selectProgram(internalID: 1)).value
        #expect(document.editingWorkspace == baseline)
      } catch { Issue.record("Explicit user reapplication should succeed: \(error)") }
      await coordinator.shutdown()
    }

    @Test func alertAcknowledgesQueuedErrorsInOrder() async throws {
      let state = WorkspaceDocument()
      let window = makeWorkspaceTestWindow(stateService: state)
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      state.operationErrors = [1, 2].map {
        NSError(
          domain: "queue", code: $0,
          userInfo: [NSLocalizedDescriptionKey: "Failure \($0)"])
      }
      for code in [1, 2] {
        var sheet: NSWindow?
        for _ in 0..<200 {
          if let current = window.attachedSheet,
            workspaceDescendants(current.contentView!).contains(where: {
              ($0 as? NSTextField)?.stringValue == "Failure \(code)"
            })
          {
            sheet = current
            break
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        let current = try #require(sheet)
        let button = try #require(
          workspaceDescendants(current.contentView!)
            .compactMap { $0 as? NSButton }.first { $0.title == "OK" })
        button.performClick(nil)
        await settleWorkspaceToolbar(window)
      }
      #expect(state.operationErrors.isEmpty)
    }

    @Test func queuesErrorsAndPreservesDetails() async throws {
      let document = WorkspaceDocument()
      let coordinator = WorkspaceAppletCoordinator(document: document)
      let error = NSError(
        domain: "test", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Edit failed.",
          NSLocalizedFailureReasonErrorKey: "A retained failure reason.",
          NSLocalizedRecoverySuggestionErrorKey: "Retry the edit.",
        ])
      coordinator.reportError(error)
      coordinator.reportError(NSError(domain: "test", code: 2))
      let state = coordinator.stateService
      #expect(state.operationErrors.first?.code == 1)
      #expect(state.operationErrors.first?.localizedFailureReason == "A retained failure reason.")
      #expect(state.operationErrors.first?.localizedRecoverySuggestion == "Retry the edit.")
      state.operationErrors.removeFirst()
      for _ in 0..<20 {
        if state.operationErrors.first != nil { break }
        await Task.yield()
      }
      #expect(state.operationErrors.first?.code == 2)
      await coordinator.shutdown()
      coordinator.reportError(error)
      #expect(state.operationErrors.first == nil)
    }

    @Test func runtimeFailuresAreScopedAndCanRecurAfterRecovery() async {
      let firstDocument = WorkspaceDocument()
      let secondDocument = WorkspaceDocument()
      let first = WorkspaceAppletCoordinator(document: firstDocument)
      let second = WorkspaceAppletCoordinator(document: secondDocument)
      first.updateMonitorFailure(-50)
      #expect(first.stateService.operationErrors.first != nil)
      #expect(second.stateService.operationErrors.first == nil)
      first.stateService.operationErrors.removeFirst()
      first.updateMonitorFailure(-50)
      #expect(first.stateService.operationErrors.first == nil)
      first.updateMonitorFailure(nil)
      first.updateMonitorFailure(-50)
      #expect(first.stateService.operationErrors.first != nil)
      await first.shutdown()
      await second.shutdown()
    }
  }
}

@MainActor
private final class SaveResultDocument: NSDocument {
  private let success: Bool
  init(success: Bool) {
    self.success = success
    super.init()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  override func save(
    withDelegate delegate: Any?, didSave selector: Selector?, contextInfo: UnsafeMutableRawPointer?
  ) {
    guard let target = delegate as? NSObject, let selector else { return }
    typealias Completion =
      @convention(c) (AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
    let completion = unsafeBitCast(target.method(for: selector), to: Completion.self)
    completion(target, selector, self, success, contextInfo)
  }
}
