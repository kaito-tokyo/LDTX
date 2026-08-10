// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AudioToolbox
import CoreMedia
import Foundation
import LDTXAppUI
import LDTXCapture
import LDTXDiagnostics
import LDTXMP4
import LDTXProgramRuntime
import LDTXWorkspace
import Testing
import os

@testable import LDTXAppCore
@testable import LDTXProgramRuntime

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

  @Test func recordCutCooldownRejectsUntilInjectedClockCompletes() async throws {
    let gate = WorkspaceCoordinatorAsyncGate()
    let coordinator = WorkspaceOutputCoordinator(
      waitForRecordCutCooldown: { await gate.wait() })
    let service = FakeSessionRecordService(name: "cut-cooldown")
    coordinator.recordService = service
    coordinator.activeMode = .record
    coordinator.lifecycleState = .running

    #expect(coordinator.requestRecordCut())
    #expect(coordinator.isRecordCutCoolingDown)
    #expect(!coordinator.requestRecordCut())

    await gate.open()
    while coordinator.isRecordCutCoolingDown { await Task.yield() }
    #expect(!coordinator.isRecordCutCoolingDown)

    coordinator.resetSession()
  }

  @Test func recordCutIsRejectedBeforeTheActiveRecordAcceptsFirstVideo() {
    let coordinator = WorkspaceOutputCoordinator()
    let service = FakeSessionRecordService(name: "not-started")
    service.hasAcceptedFirstVideo = false
    coordinator.recordService = service
    coordinator.activeMode = .record
    coordinator.lifecycleState = .running

    #expect(!coordinator.requestRecordCut())
  }

  @Test func recordAuxiliaryOperationIsRejectedBeforeTheActiveRecordAcceptsFirstVideo() {
    let coordinator = WorkspaceOutputCoordinator()
    let service = FakeSessionRecordService(name: "not-started")
    service.hasAcceptedFirstVideo = false
    coordinator.recordService = service

    #expect(coordinator.beginRecordAuxiliaryOperation() == nil)
  }

  @Test func recordCutCommitsSyncBoundaryOnceAndPreservesMediaOrder() async throws {
    let coordinator = WorkspaceOutputCoordinator()
    let hub = ProgramOutputMediaHub()
    let previous = FakeSessionRecordService(name: "previous")
    let next = FakeSessionRecordService(name: "next")
    var controlOperations: [@MainActor @Sendable () -> Void] = []
    coordinator.installRecordService(
      previous,
      on: hub,
      makeNext: { next },
      enqueueControl: {
        controlOperations.append($0)
        return true
      },
      eventHandler: { _ in })
    coordinator.activeMode = .record
    coordinator.lifecycleState = .running

    #expect(coordinator.requestRecordCut())
    await coordinator.waitForRecordMediaDelivery()
    coordinator.receiveRecordVideo(try recordSample(pts: 1, isSync: false))
    coordinator.receiveRecordVideo(try recordSample(pts: 2, isSync: true))
    coordinator.receiveRecordMainAudio(try recordPCMSample(pts: 1.9))
    coordinator.appendRecordInputAudio(try recordSample(pts: 1.8), trackID: "input")
    coordinator.receiveRecordMainAudio(try recordPCMSample(pts: 2.1))
    coordinator.appendRecordInputAudio(try recordSample(pts: 2.2), trackID: "input")
    coordinator.receiveRecordVideo(try recordSample(pts: 2.3, isSync: false))

    #expect(previous.events == ["video:1.0", "main-audio:1.9", "input:input:1.8"])
    while controlOperations.isEmpty { await Task.yield() }
    controlOperations.removeFirst()()
    await coordinator.waitForRecordMediaOperations()

    #expect(coordinator.recordService === next)
    #expect(next.events == ["first-video:2.0", "main-audio:2.1", "input:input:2.2", "video:2.3"])
    #expect(previous.stopCount == 1)
    #expect(previous.finishAfterCutCount == 1)
  }

  @Test func recordCutRoutesQueuedPreBoundaryAudioToThePreviousRecord() async throws {
    let coordinator = WorkspaceOutputCoordinator()
    let hub = ProgramOutputMediaHub()
    let previous = FakeSessionRecordService(name: "previous")
    let next = FakeSessionRecordService(name: "next")
    var controlOperations: [@MainActor @Sendable () -> Void] = []
    coordinator.installRecordService(
      previous,
      on: hub,
      makeNext: { next },
      enqueueControl: {
        controlOperations.append($0)
        return true
      },
      eventHandler: { _ in })
    coordinator.activeMode = .record
    coordinator.lifecycleState = .running

    hub.publishMainAudioMix(try recordPCMSample(pts: 1.9))
    while previous.events.isEmpty { await Task.yield() }
    #expect(coordinator.requestRecordCut())
    await coordinator.waitForRecordMediaDelivery()
    coordinator.receiveRecordVideo(try recordSample(pts: 2, isSync: true))
    while controlOperations.isEmpty { await Task.yield() }
    controlOperations.removeFirst()()
    await coordinator.waitForRecordMediaOperations()

    while previous.stopCount == 0 { await Task.yield() }
    #expect(previous.events == ["main-audio:1.9"])
    #expect(next.events == ["first-video:2.0"])
    #expect(previous.stopCount == 1)
  }

  @Test func recordCutWaitsForLatePreBoundaryInputCallbackBeforeFinalizing() async throws {
    let copyStarted = DispatchSemaphore(value: 0)
    let releaseCopy = DispatchSemaphore(value: 0)
    let coordinator = WorkspaceOutputCoordinator(
      copyRecordInputAudioSample: { sampleBuffer in
        copyStarted.signal()
        releaseCopy.wait()
        return try ProgramOwnedPCMSampleBuffer(copying: sampleBuffer)
      })
    let hub = ProgramOutputMediaHub()
    let previous = FakeSessionRecordService(name: "previous-late-input")
    let next = FakeSessionRecordService(name: "next-late-input")
    var controlOperations: [@MainActor @Sendable () -> Void] = []
    coordinator.installRecordService(
      previous,
      on: hub,
      makeNext: { next },
      enqueueControl: {
        controlOperations.append($0)
        return true
      },
      eventHandler: { _ in })
    coordinator.activeMode = .record
    coordinator.lifecycleState = .running
    coordinator.receiveRecordMainAudio(try recordPCMSample(pts: 0.5))

    let capture = ImmediateTestAudioCapture()
    let captureCoordinator = WorkspaceCaptureSessionCoordinator(
      captureServiceFactory: { CameraCaptureService() },
      audioCaptureServiceFactory: { capture })
    await withCheckedContinuation { continuation in
      coordinator.installRecordInputAudioSubscriptions(
        tracks: [
          SessionRecordAudioTrack(
            key: "input", deviceID: "device", trackID: "input",
            displayName: "Input", fileNameStem: "InputDevices/Input")
        ],
        captureSessionCoordinator: captureCoordinator,
        failureHandler: { error in Issue.record("Unexpected capture failure: \(error)") },
        completionHandler: { continuation.resume() })
    }

    let lateSample = TestSendableSampleBuffer(value: try recordPCMSample(pts: 1))
    let emission = Task.detached {
      capture.emit(lateSample.value)
    }
    #expect(
      await Task.detached {
        waitForSemaphore(copyStarted, timeout: .now() + 1)
      }.value)

    #expect(coordinator.requestRecordCut())
    await coordinator.waitForRecordMediaDelivery()
    coordinator.receiveRecordVideo(try recordSample(pts: 2, isSync: true))
    while controlOperations.isEmpty { await Task.yield() }
    controlOperations.removeFirst()()
    await coordinator.waitForRecordMediaOperations()
    #expect(previous.stopCount == 0)

    releaseCopy.signal()
    await emission.value
    while previous.stopCount == 0 { await Task.yield() }

    #expect(previous.events.contains("input:input:1.0"))
    #expect(!next.events.contains("input:input:1.0"))
    #expect(previous.finishAfterCutCount == 1)
  }

  @Test func recordMediaDeliveryContinuesWhileMainActorIsOccupied() async throws {
    let coordinator = WorkspaceOutputCoordinator()
    let hub = ProgramOutputMediaHub()
    let service = FakeSessionRecordService(name: "main-actor-independent")
    let delivered = DispatchSemaphore(value: 0)
    service.eventHandler = { event in
      if event.hasPrefix("video:") { delivered.signal() }
    }
    coordinator.installRecordService(
      service,
      on: hub,
      makeNext: { FakeSessionRecordService(name: "unused") },
      enqueueControl: { _ in false },
      eventHandler: { _ in })
    let sample = try recordSample(pts: 1, isSync: false)
    let mainActorBlocked = DispatchSemaphore(value: 0)
    let releaseMainActor = DispatchSemaphore(value: 0)
    Task { @MainActor in
      mainActorBlocked.signal()
      waitForSemaphore(releaseMainActor)
    }

    let progressed = await Task.detached {
      guard waitForSemaphore(mainActorBlocked, timeout: .now() + 1) else { return false }
      hub.publishMainVideo(sample)
      let progressed = waitForSemaphore(delivered, timeout: .now() + 1)
      releaseMainActor.signal()
      return progressed
    }.value

    #expect(progressed)
  }

  @Test func recordCutRollsBackWholeBoundaryWhenCommitExceedsSixtySeconds() async throws {
    let coordinator = WorkspaceOutputCoordinator()
    let previous = FakeSessionRecordService(name: "previous")
    let next = FakeSessionRecordService(name: "next")
    var controlOperations: [@MainActor @Sendable () -> Void] = []
    coordinator.installRecordService(
      previous,
      on: ProgramOutputMediaHub(),
      makeNext: { next },
      enqueueControl: {
        controlOperations.append($0)
        return true
      },
      eventHandler: { _ in })
    coordinator.activeMode = .record
    coordinator.lifecycleState = .running

    #expect(coordinator.requestRecordCut())
    await coordinator.waitForRecordMediaDelivery()
    coordinator.receiveRecordVideo(try recordSample(pts: 10, isSync: true))
    coordinator.receiveRecordMainAudio(try recordPCMSample(pts: 70))
    #expect(previous.events.isEmpty)
    coordinator.receiveRecordMainAudio(try recordPCMSample(pts: 70.001))

    #expect(previous.events == ["video:10.0", "main-audio:70.0", "main-audio:70.001"])
    #expect(coordinator.recordService === previous)
    #expect(next.events.isEmpty)
    while controlOperations.isEmpty { await Task.yield() }
    controlOperations.removeFirst()()
    await coordinator.waitForRecordMediaOperations()
    #expect(next.events.isEmpty)
  }

  @Test func recordCutFirstVideoFailureKeepsPreviousServiceAndReplaysBoundary() async throws {
    let coordinator = WorkspaceOutputCoordinator()
    let previous = FakeSessionRecordService(name: "previous")
    let next = FakeSessionRecordService(name: "next")
    next.firstVideoError = FakeRecordError.expected
    var controlOperations: [@MainActor @Sendable () -> Void] = []
    coordinator.installRecordService(
      previous,
      on: ProgramOutputMediaHub(),
      makeNext: { next },
      enqueueControl: {
        controlOperations.append($0)
        return true
      },
      eventHandler: { _ in })
    coordinator.activeMode = .record
    coordinator.lifecycleState = .running

    #expect(coordinator.requestRecordCut())
    await coordinator.waitForRecordMediaDelivery()
    coordinator.receiveRecordVideo(try recordSample(pts: 1, isSync: true))
    coordinator.receiveRecordMainAudio(try recordPCMSample(pts: 1.1))
    while controlOperations.isEmpty { await Task.yield() }
    controlOperations.removeFirst()()
    await coordinator.waitForRecordMediaOperations()

    #expect(coordinator.recordService === previous)
    #expect(previous.events == ["video:1.0", "main-audio:1.1"])
    #expect(next.cancelCount == 1)
    #expect(previous.stopCount == 0)
  }

  @Test func stoppingDefersPendingCutRollbackUntilQueuedCommitRuns() async throws {
    let coordinator = WorkspaceOutputCoordinator()
    let previous = FakeSessionRecordService(name: "previous")
    var controlOperations: [@MainActor @Sendable () -> Void] = []
    coordinator.installRecordService(
      previous,
      on: ProgramOutputMediaHub(),
      makeNext: { FakeSessionRecordService(name: "unused") },
      enqueueControl: {
        controlOperations.append($0)
        return true
      },
      eventHandler: { _ in })
    coordinator.activeMode = .record
    coordinator.lifecycleState = .running

    #expect(coordinator.requestRecordCut())
    await coordinator.waitForRecordMediaDelivery()
    coordinator.receiveRecordVideo(try recordSample(pts: 1, isSync: true))
    coordinator.receiveRecordMainAudio(try recordPCMSample(pts: 1.1))
    coordinator.appendRecordInputAudio(try recordSample(pts: 1.2), trackID: "input")
    _ = coordinator.invalidateOperations(for: .stopping)

    #expect(previous.events.isEmpty)
    while controlOperations.isEmpty { await Task.yield() }
    controlOperations.removeFirst()()
    await coordinator.waitForRecordMediaOperations()
    #expect(previous.events == ["video:1.0", "main-audio:1.1", "input:input:1.2"])
    #expect(coordinator.recordService === previous)
  }

  @Test func recordScreenshotLeaseDefersOldFinalizerUntilControlQueueRelease() async throws {
    let coordinator = WorkspaceOutputCoordinator()
    let previous = FakeSessionRecordService(name: "previous")
    let next = FakeSessionRecordService(name: "next")
    var controlOperations: [@MainActor @Sendable () -> Void] = []
    coordinator.installRecordService(
      previous,
      on: ProgramOutputMediaHub(),
      makeNext: { next },
      enqueueControl: {
        controlOperations.append($0)
        return true
      },
      eventHandler: { _ in })
    coordinator.activeMode = .record
    coordinator.lifecycleState = .running
    let lease = try #require(coordinator.beginRecordAuxiliaryOperation())

    coordinator.receiveRecordMainAudio(try recordPCMSample(pts: 0.9))
    #expect(coordinator.requestRecordCut())
    await coordinator.waitForRecordMediaDelivery()
    coordinator.receiveRecordVideo(try recordSample(pts: 1, isSync: true))
    while controlOperations.isEmpty { await Task.yield() }
    controlOperations.removeFirst()()
    await coordinator.waitForRecordMediaOperations()
    #expect(previous.stopCount == 0)

    coordinator.endRecordAuxiliaryOperation(lease)
    #expect(previous.stopCount == 0)
    while controlOperations.isEmpty { await Task.yield() }
    controlOperations.removeFirst()()
    await coordinator.waitForRecordMediaOperations()
    #expect(previous.stopCount == 1)
  }

  @Test func rejectedScreenshotLeaseReleaseRemainsDeferredUntilStop() async throws {
    let coordinator = WorkspaceOutputCoordinator()
    let previous = FakeSessionRecordService(name: "previous")
    let next = FakeSessionRecordService(name: "next")
    var acceptsControl = true
    var controlOperations: [@MainActor @Sendable () -> Void] = []
    coordinator.installRecordService(
      previous,
      on: ProgramOutputMediaHub(),
      makeNext: { next },
      enqueueControl: {
        guard acceptsControl else { return false }
        controlOperations.append($0)
        return true
      },
      eventHandler: { _ in })
    coordinator.activeMode = .record
    coordinator.lifecycleState = .running
    let lease = try #require(coordinator.beginRecordAuxiliaryOperation())

    coordinator.receiveRecordMainAudio(try recordPCMSample(pts: 0.9))
    #expect(coordinator.requestRecordCut())
    await coordinator.waitForRecordMediaDelivery()
    coordinator.receiveRecordVideo(try recordSample(pts: 1, isSync: true))
    while controlOperations.isEmpty { await Task.yield() }
    controlOperations.removeFirst()()
    await coordinator.waitForRecordMediaOperations()
    acceptsControl = false
    coordinator.endRecordAuxiliaryOperation(lease)
    #expect(previous.stopCount == 0)

    _ = await coordinator.stopRecordService()
    #expect(previous.stopCount == 1)
    #expect(next.stopCount == 1)
  }

  @Test func failedOldFinalizerDoesNotStopNewActiveRecordingOrLogSuccess() async throws {
    let coordinator = WorkspaceOutputCoordinator()
    let previous = FakeSessionRecordService(name: "previous")
    previous.finalizationResult = .failed(FakeRecordError.expected)
    let next = FakeSessionRecordService(name: "next")
    var controlOperations: [@MainActor @Sendable () -> Void] = []
    var messages: [String] = []
    coordinator.installRecordService(
      previous,
      on: ProgramOutputMediaHub(),
      makeNext: { next },
      enqueueControl: {
        controlOperations.append($0)
        return true
      },
      eventHandler: { messages.append($0) })
    coordinator.activeMode = .record
    coordinator.lifecycleState = .running

    coordinator.receiveRecordMainAudio(try recordPCMSample(pts: 0.9))
    #expect(coordinator.requestRecordCut())
    await coordinator.waitForRecordMediaDelivery()
    coordinator.receiveRecordVideo(try recordSample(pts: 1, isSync: true))
    while controlOperations.isEmpty { await Task.yield() }
    controlOperations.removeFirst()()
    await coordinator.waitForRecordMediaOperations()

    #expect(coordinator.recordService === next)
    #expect(next.stopCount == 0)
    #expect(messages.contains { $0.contains("Recording finalize failed") })
    #expect(!messages.contains { $0.contains("Finalized recording") })
  }

  @Test func stopReportsFailedCutFinalizerAfterActiveRecordingFinalizes() async throws {
    let coordinator = WorkspaceOutputCoordinator()
    let previous = FakeSessionRecordService(name: "previous")
    previous.finalizationResult = .failed(FakeRecordError.expected)
    let next = FakeSessionRecordService(name: "next")
    var controlOperations: [@MainActor @Sendable () -> Void] = []
    coordinator.installRecordService(
      previous,
      on: ProgramOutputMediaHub(),
      makeNext: { next },
      enqueueControl: {
        controlOperations.append($0)
        return true
      },
      eventHandler: { _ in })
    coordinator.activeMode = .record
    coordinator.lifecycleState = .running

    coordinator.receiveRecordMainAudio(try recordPCMSample(pts: 0.9))
    #expect(coordinator.requestRecordCut())
    await coordinator.waitForRecordMediaDelivery()
    coordinator.receiveRecordVideo(try recordSample(pts: 1, isSync: true))
    while controlOperations.isEmpty { await Task.yield() }
    controlOperations.removeFirst()()
    await coordinator.waitForRecordMediaOperations()

    let result = await coordinator.stopRecordService()
    guard case .failure(let error) = result else {
      Issue.record("Expected failed Cut finalizer to be reported at Stop")
      return
    }
    #expect(error is FakeRecordError)
    #expect(next.stopCount == 1)
  }

  @Test func stopDrainsQueuedInputAudioBeforeSealingRecordService() async throws {
    let capture = ImmediateTestAudioCapture()
    let captureCoordinator = WorkspaceCaptureSessionCoordinator(
      captureServiceFactory: { CameraCaptureService() },
      audioCaptureServiceFactory: { capture })
    let coordinator = WorkspaceOutputCoordinator()
    let service = FakeSessionRecordService(name: "active")
    service.recordsStopEvent = true
    coordinator.recordService = service

    await withCheckedContinuation { continuation in
      coordinator.installRecordInputAudioSubscriptions(
        tracks: [
          SessionRecordAudioTrack(
            key: "input", deviceID: "device", trackID: "input",
            displayName: "Input", fileNameStem: "InputDevices/Input")
        ],
        captureSessionCoordinator: captureCoordinator,
        failureHandler: { error in Issue.record("Unexpected capture failure: \(error)") },
        completionHandler: { continuation.resume() })
    }

    capture.emit(try recordPCMSample(pts: 1))
    _ = await coordinator.stopRecordService()

    #expect(service.events == ["input:input:1.0", "stop"])
  }

  @Test func recordDrainTimeoutDoesNotReenterTheStalledMediaQueue() async throws {
    let coordinator = WorkspaceOutputCoordinator(recordMediaDrainTimeout: .milliseconds(20))
    let hub = ProgramOutputMediaHub()
    let service = FakeSessionRecordService(name: "stalled-record-media")
    let appendStarted = DispatchSemaphore(value: 0)
    let releaseAppend = DispatchSemaphore(value: 0)
    service.eventHandler = { event in
      guard event.hasPrefix("video:") else { return }
      appendStarted.signal()
      releaseAppend.wait()
    }
    coordinator.installRecordService(
      service,
      on: hub,
      makeNext: { FakeSessionRecordService(name: "unused") },
      enqueueControl: { _ in false },
      eventHandler: { _ in })
    coordinator.activeMode = .record
    coordinator.lifecycleState = .running
    hub.publishMainVideo(try recordSample(pts: 1, isSync: false))
    #expect(
      await Task.detached {
        waitForSemaphore(appendStarted, timeout: .now() + 1)
      }.value)

    #expect(coordinator.requestRecordCut())
    _ = coordinator.invalidateOperations(for: .stopping)
    let result = await coordinator.stopRecordService()
    coordinator.resetSession()

    let replacementHub = ProgramOutputMediaHub()
    let replacement = FakeSessionRecordService(name: "replacement-record-media")
    let replacementAppendCompleted = DispatchSemaphore(value: 0)
    replacement.eventHandler = { event in
      guard event.hasPrefix("video:") else { return }
      replacementAppendCompleted.signal()
    }
    coordinator.installRecordService(
      replacement,
      on: replacementHub,
      makeNext: { FakeSessionRecordService(name: "unused") },
      enqueueControl: { _ in false },
      eventHandler: { _ in })
    replacementHub.publishMainVideo(try recordSample(pts: 2, isSync: false))
    #expect(
      await Task.detached {
        waitForSemaphore(replacementAppendCompleted, timeout: .now() + 1)
      }.value)

    releaseAppend.signal()

    guard case .failure(let error) = result else {
      Issue.record("Expected the stalled Record media core to time out")
      return
    }
    #expect(error as? ProgramOutputMediaChannelError == .drainTimedOut)
    #expect(service.stopCount == 0)
    #expect(service.abandonCount == 1)
    #expect(replacement.events == ["video:2.0"])
  }

  @Test func youtubeStopReturnsHubDrainTimeout() async throws {
    let coordinator = WorkspaceOutputCoordinator()
    let hub = ProgramOutputMediaHub()
    coordinator.currentMediaHub = hub
    let service = FakeYouTubeOutputWorkspaceService()
    let appendStarted = DispatchSemaphore(value: 0)
    let releaseAppend = DispatchSemaphore(value: 0)
    service.videoHandler = {
      appendStarted.signal()
      releaseAppend.wait()
    }
    coordinator.installYouTubeService(
      service,
      on: hub,
      limits: ProgramOutputMediaChannelLimits(drainTimeout: .milliseconds(20)))
    hub.publishMainVideo(try recordSample(pts: 1, isSync: false))
    #expect(await Task.detached { waitForSemaphore(appendStarted, timeout: .now() + 1) }.value)

    let result = await coordinator.stopYouTubeService()
    releaseAppend.signal()

    guard case .failure(let error) = result else {
      Issue.record("Expected the stalled YouTube Hub channel to time out")
      return
    }
    #expect(error as? ProgramOutputMediaChannelError == .drainTimedOut)
    #expect(service.failureCount == 1)
    #expect(service.stopCount == 1)
  }

  @Test func inputCaptureCallbackDoesNotWaitForStalledRecordMediaQueue() async throws {
    let capture = ImmediateTestAudioCapture()
    let captureCoordinator = WorkspaceCaptureSessionCoordinator(
      captureServiceFactory: { CameraCaptureService() },
      audioCaptureServiceFactory: { capture })
    let copyStarted = DispatchSemaphore(value: 0)
    let coordinator = WorkspaceOutputCoordinator(
      copyRecordInputAudioSample: { sampleBuffer in
        copyStarted.signal()
        return try ProgramOwnedPCMSampleBuffer(copying: sampleBuffer)
      })
    let hub = ProgramOutputMediaHub()
    let service = FakeSessionRecordService(name: "stalled-before-input-callback")
    let appendStarted = DispatchSemaphore(value: 0)
    let releaseAppend = DispatchSemaphore(value: 0)
    service.eventHandler = { event in
      guard event.hasPrefix("video:") else { return }
      appendStarted.signal()
      releaseAppend.wait()
    }
    coordinator.installRecordService(
      service,
      on: hub,
      makeNext: { FakeSessionRecordService(name: "unused") },
      enqueueControl: { _ in false },
      eventHandler: { _ in })
    await withCheckedContinuation { continuation in
      coordinator.installRecordInputAudioSubscriptions(
        tracks: [
          SessionRecordAudioTrack(
            key: "input", deviceID: "device", trackID: "input",
            displayName: "Input", fileNameStem: "InputDevices/Input")
        ],
        captureSessionCoordinator: captureCoordinator,
        failureHandler: { error in Issue.record("Unexpected capture failure: \(error)") },
        completionHandler: { continuation.resume() })
    }

    hub.publishMainVideo(try recordSample(pts: 1, isSync: false))
    #expect(await Task.detached { waitForSemaphore(appendStarted, timeout: .now() + 1) }.value)
    let emit = Task.detached { capture.emit(try! recordPCMSample(pts: 1)) }
    #expect(await Task.detached { waitForSemaphore(copyStarted, timeout: .now() + 1) }.value)

    releaseAppend.signal()
    await emit.value
    _ = await coordinator.stopRecordService()
  }

  @Test func ownedPCMCopyPreservesTimingOutsideCaptureStorage() throws {
    let source = try recordPCMSample(pts: 1)
    let copy = try ProgramOwnedPCMSampleBuffer(copying: source).value

    #expect(copy.presentationTimeStamp.seconds == 1)
    #expect(CMSampleBufferGetNumSamples(copy) == 1)
    #expect(copy.dataBuffer !== source.dataBuffer)
  }

  @Test func stopServicesReturnsActiveRecordingFinalizationFailure() async {
    let coordinator = WorkspaceOutputCoordinator()
    let service = FakeSessionRecordService(name: "active")
    service.finalizationResult = .failed(FakeRecordError.expected)
    coordinator.recordService = service

    // SessionTaskQueue finalization stops recording before the output services
    // collect and present their combined result.
    _ = await coordinator.stopRecordService()
    let result = await coordinator.stopServices()

    guard case .failure(let error) = result else {
      Issue.record("Expected active recording finalization failure")
      return
    }
    #expect(error is FakeRecordError)
    #expect(service.stopCount == 1)
  }

  @Test func stopWaitsForFailedReplacementCancellation() async throws {
    let coordinator = WorkspaceOutputCoordinator()
    let previous = FakeSessionRecordService(name: "previous")
    let replacement = FakeSessionRecordService(name: "replacement")
    replacement.firstVideoError = FakeRecordError.expected
    replacement.completesCancelImmediately = false
    var controlOperations: [@MainActor @Sendable () -> Void] = []
    coordinator.installRecordService(
      previous,
      on: ProgramOutputMediaHub(),
      makeNext: { replacement },
      enqueueControl: {
        controlOperations.append($0)
        return true
      },
      eventHandler: { _ in })
    coordinator.activeMode = .record
    coordinator.lifecycleState = .running

    coordinator.receiveRecordMainAudio(try recordPCMSample(pts: 0.9))
    #expect(coordinator.requestRecordCut())
    await coordinator.waitForRecordMediaDelivery()
    coordinator.receiveRecordVideo(try recordSample(pts: 1, isSync: true))
    while controlOperations.isEmpty { await Task.yield() }
    controlOperations.removeFirst()()
    await coordinator.waitForRecordMediaOperations()
    #expect(replacement.cancelCount == 1)

    var stopCompleted = false
    let stopTask = Task { @MainActor in
      _ = await coordinator.stopRecordService()
      stopCompleted = true
    }
    while previous.stopCount == 0 { await Task.yield() }
    await Task.yield()
    #expect(!stopCompleted)

    replacement.completePendingCancel()
    await stopTask.value
    #expect(stopCompleted)
  }

  @Test func stopWaitsForActiveAndEveryOverlappingRecordFinalizer() async throws {
    let coordinator = WorkspaceOutputCoordinator(waitForRecordCutCooldown: {})
    let first = FakeSessionRecordService(name: "first")
    let second = FakeSessionRecordService(name: "second")
    let third = FakeSessionRecordService(name: "third")
    first.completesStopImmediately = false
    second.completesStopImmediately = false
    third.completesStopImmediately = false
    var replacements = [second, third]
    var controlOperations: [@MainActor @Sendable () -> Void] = []
    coordinator.installRecordService(
      first,
      on: ProgramOutputMediaHub(),
      makeNext: { replacements.removeFirst() },
      enqueueControl: {
        controlOperations.append($0)
        return true
      },
      eventHandler: { _ in })
    coordinator.activeMode = .record
    coordinator.lifecycleState = .running

    coordinator.receiveRecordMainAudio(try recordPCMSample(pts: 0.9))
    #expect(coordinator.requestRecordCut())
    await coordinator.waitForRecordMediaDelivery()
    coordinator.receiveRecordVideo(try recordSample(pts: 1, isSync: true))
    while controlOperations.isEmpty { await Task.yield() }
    controlOperations.removeFirst()()
    await coordinator.waitForRecordMediaOperations()
    while coordinator.isRecordCutCoolingDown { await Task.yield() }
    coordinator.receiveRecordMainAudio(try recordPCMSample(pts: 1.9))
    #expect(coordinator.requestRecordCut())
    await coordinator.waitForRecordMediaDelivery()
    coordinator.receiveRecordVideo(try recordSample(pts: 2, isSync: true))
    while controlOperations.isEmpty { await Task.yield() }
    controlOperations.removeFirst()()
    await coordinator.waitForRecordMediaOperations()
    #expect(first.stopCount == 1)
    #expect(second.stopCount == 1)

    var stopCompleted = false
    let stopTask = Task { @MainActor in
      _ = await coordinator.stopRecordService()
      stopCompleted = true
    }
    while third.stopCount == 0 { await Task.yield() }
    #expect(!stopCompleted)

    third.completePendingStop()
    await Task.yield()
    #expect(!stopCompleted)
    first.completePendingStop()
    await Task.yield()
    #expect(!stopCompleted)
    second.completePendingStop()
    await stopTask.value
    #expect(stopCompleted)
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

  @Test func interruptUnlocksAfterDiscardingPendingOutputOperation() async {
    let coordinator = WorkspaceEventCoordinator(logger: .disabled)
    let running = AsyncTestGate()

    coordinator.enqueue { _ in
      await running.wait()
    }
    coordinator.enqueue { _ in
      Issue.record("Discarded output operation unexpectedly ran")
    }
    #expect(coordinator.isLocked)

    let interrupt = Task { @MainActor in
      await coordinator.interrupt()
    }
    await Task.yield()
    #expect(coordinator.isLocked)

    running.open()
    await interrupt.value
    #expect(!coordinator.isLocked)
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

  @Test func persistenceCoordinatorWritesAutomaticSaveOutsideMainThread() async throws {
    let packageURL = temporaryWorkspacePackageURL()
    defer { try? FileManager.default.removeItem(at: packageURL) }
    let probe = WorkspacePersistenceThreadProbe()
    let packageService = makeFailingWorkspacePackageService(probe: probe)
    let store = try WorkspaceStore(clean: WorkspaceDefinition())
    store.edit { $0.name = "Saved away from MainActor" }
    let coordinator = WorkspacePersistenceCoordinator(
      store: store,
      packageService: packageService
    )

    var didThrow = false
    do {
      try await coordinator.saveInBackground(store, to: packageURL)
    } catch {
      didThrow = true
    }

    #expect(didThrow)
    #expect(store.isDirty)
    #expect(!probe.values.isEmpty)
    #expect(probe.values.allSatisfy { !$0 })
  }

  @Test func explicitSaveInvalidatesPendingAutomaticSaveCompletion() async throws {
    let firstURL = temporaryWorkspacePackageURL()
    let secondURL = temporaryWorkspacePackageURL()
    defer {
      try? FileManager.default.removeItem(at: firstURL)
      try? FileManager.default.removeItem(at: secondURL)
    }
    let probe = BlockingWorkspaceWriteProbe()
    let store = try WorkspaceStore(clean: WorkspaceDefinition(name: "Workspace"))
    let coordinator = WorkspacePersistenceCoordinator(
      store: store,
      url: firstURL,
      packageService: makeBlockingWorkspacePackageService(probe: probe)
    )
    var automaticSaveCompletionCount = 0
    coordinator.scheduleAutomaticSave(store, to: firstURL) { _ in
      automaticSaveCompletionCount += 1
    }
    #expect(
      await Task.detached {
        waitForSemaphore(probe.firstWriteStarted, timeout: .now() + 10)
      }.value)

    probe.releaseFirstWrite.signal()
    try coordinator.save(store, to: secondURL)
    coordinator.replace(store: store, url: secondURL)
    await Task.yield()

    #expect(automaticSaveCompletionCount == 0)
    #expect(coordinator.url == secondURL)
  }

  @Test func stoppingAutomaticSaveDrainsWriteBeforeReturning() async throws {
    let packageURL = temporaryWorkspacePackageURL()
    defer { try? FileManager.default.removeItem(at: packageURL) }
    let probe = BlockingWorkspaceWriteProbe()
    let store = try WorkspaceStore(clean: WorkspaceDefinition(name: "Workspace"))
    let coordinator = WorkspacePersistenceCoordinator(
      store: store,
      url: packageURL,
      packageService: makeBlockingWorkspacePackageService(probe: probe)
    )
    coordinator.scheduleAutomaticSave(store, to: packageURL) { _ in
      Issue.record("Cancelled automatic save unexpectedly completed")
    }
    #expect(
      await Task.detached {
        waitForSemaphore(probe.firstWriteStarted, timeout: .now() + 10)
      }.value)

    let stopped = WorkspaceStopProbe()
    let stopTask = Task { @MainActor in
      await coordinator.stopAutomaticSave()
      stopped.markStopped()
    }
    await Task.yield()
    #expect(!stopped.isStopped)

    probe.releaseFirstWrite.signal()
    await stopTask.value
    #expect(stopped.isStopped)
  }

  @Test func persistenceCoordinatorProjectsRuntimeDevicesFromOneWorkspaceStore() throws {
    let persistedDevice = WorkspaceInputDeviceRecord(
      name: "Camera", kind: .video)
    let store = try WorkspaceStore(
      clean: WorkspaceDefinition(
        inputDevices: [persistedDevice]))
    store.editPreferences {
      $0.physicalDeviceIDsByInputDeviceID[persistedDevice.id] = "camera-1"
    }
    let coordinator = WorkspacePersistenceCoordinator(store: store)

    #expect(coordinator.runtimeInputDevices.first?.physicalDeviceID == "camera-1")

    coordinator.runtimeInputDevices = [
      WorkspaceInputDeviceRecord(
        name: "Camera", kind: .video, physicalDeviceID: "camera-2")
    ]

    #expect(coordinator.store.definition.inputDevices.first?.physicalDeviceID == nil)
    #expect(
      coordinator.store.preferences.physicalDeviceIDsByInputDeviceID[persistedDevice.id]
        == "camera-2")
  }

  @Test func persistenceCoordinatorPublishesProgramPreferenceRevisionsFromTheStore() throws {
    let coordinator = WorkspacePersistenceCoordinator(
      store: try WorkspaceStore(clean: WorkspaceDefinition()))
    var preferences = coordinator.programPreferences
    preferences.setVideoMuted(true, inputDeviceName: "Camera")

    coordinator.replaceProgramPreferences(with: preferences)

    #expect(coordinator.store.preferences.programPreferences == preferences)
    #expect(coordinator.programPreferencesRevision == 1)
    coordinator.replaceProgramPreferences(with: preferences)
    #expect(coordinator.programPreferencesRevision == 1)
  }

  @Test func persistenceCoordinatorPublishesInPlaceProgramPreferenceChanges() throws {
    let store = try WorkspaceStore(clean: WorkspaceDefinition())
    let coordinator = WorkspacePersistenceCoordinator(store: store)
    store.editPreferences {
      $0.programPreferences.setVideoMuted(true, inputDeviceName: "Camera")
    }

    coordinator.replace(store: store, url: nil)

    #expect(coordinator.programPreferencesRevision == 1)
    coordinator.replace(store: store, url: nil)
    #expect(coordinator.programPreferencesRevision == 1)
  }

  @Test func workspacePreferenceSnapshotsApplyWithoutOverlappingStoreAccess() throws {
    let store = try WorkspaceStore(clean: WorkspaceDefinition())
    var programPreferences = store.preferences.programPreferences
    programPreferences.setVideoLayers([], forProgramNamed: "Saved Program")
    let snapshots = WorkspacePreferenceSnapshots(
      programPreferences: programPreferences,
      physicalDeviceIDsByInputDeviceID: ["camera": "physical-camera"],
      inputCameraDeviceMappings: ["camera": "capture-camera"],
      inputAudioDeviceMappings: ["microphone": "capture-microphone"],
      inputAudioMonitorChannelKeys: ["microphone"],
      selectedProgramName: "Saved Program",
      outputDestination: OutputDestination()
    )

    store.editPreferences { preferences in
      snapshots.apply(to: &preferences)
    }

    #expect(store.preferences.programPreferences == programPreferences)
    #expect(store.preferences.physicalDeviceIDsByInputDeviceID == ["camera": "physical-camera"])
    #expect(store.preferences.inputCameraDeviceMappings == ["camera": "capture-camera"])
    #expect(store.preferences.inputAudioDeviceMappings == ["microphone": "capture-microphone"])
    #expect(store.preferences.inputAudioMonitorChannelKeys == ["microphone"])
    #expect(store.preferences.selectedProgramName == "Saved Program")
  }

  @Test func persistenceCoordinatorCommitsEditorProjectionsWithoutReplacingDomainState() throws {
    let inputDevice = WorkspaceInputDeviceRecord(name: "Camera", kind: .video)
    let store = try WorkspaceStore(clean: WorkspaceDefinition(inputDevices: [inputDevice]))
    let coordinator = WorkspacePersistenceCoordinator(store: store)
    let outputConfiguration = WorkspaceOutputConfiguration(
      canvasWidth: 1280,
      canvasHeight: 720,
      frameRate: 30,
      videoBitRate: 4_000_000)

    coordinator.commitEditorProjections(
      workspaceName: "Renamed",
      programs: [],
      outputConfiguration: outputConfiguration)

    #expect(coordinator.store.definition.name == "Renamed")
    #expect(coordinator.store.definition.outputConfiguration == outputConfiguration)
    #expect(coordinator.store.definition.inputDevices == [inputDevice])
  }

  private func temporaryWorkspacePackageURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("LDTXWorkspaceLockTests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("Test.ldtxworkspace", isDirectory: true)
  }
}

private final class WorkspacePersistenceThreadProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Bool] = []

  var values: [Bool] { lock.withLock { storage } }

  func append(_ value: Bool) {
    lock.withLock { storage.append(value) }
  }
}

private func makeFailingWorkspacePackageService(
  probe: WorkspacePersistenceThreadProbe
) -> WorkspacePackageService {
  WorkspacePackageService(writeData: { _, _ in
    probe.append(Thread.isMainThread)
    throw CocoaError(.fileWriteUnknown)
  })
}

private final class BlockingWorkspaceWriteProbe: @unchecked Sendable {
  let firstWriteStarted = DispatchSemaphore(value: 0)
  let releaseFirstWrite = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var hasStartedFirstWrite = false

  func write(_ data: Data, to url: URL) throws {
    let shouldBlock = lock.withLock { () -> Bool in
      guard !hasStartedFirstWrite else { return false }
      hasStartedFirstWrite = true
      return true
    }
    if shouldBlock {
      firstWriteStarted.signal()
      releaseFirstWrite.wait()
    }
    try data.write(to: url, options: [.atomic])
  }
}

private final class WorkspaceStopProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false

  var isStopped: Bool { lock.withLock { stopped } }

  func markStopped() {
    lock.withLock { stopped = true }
  }
}

private func makeBlockingWorkspacePackageService(
  probe: BlockingWorkspaceWriteProbe
) -> WorkspacePackageService {
  WorkspacePackageService(writeData: { data, url in
    try probe.write(data, to: url)
  })
}

private actor WorkspaceCoordinatorAsyncGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isOpen = false

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}

private func waitForSemaphore(_ semaphore: DispatchSemaphore) {
  semaphore.wait()
}

private func waitForSemaphore(
  _ semaphore: DispatchSemaphore,
  timeout: DispatchTime
) -> Bool {
  semaphore.wait(timeout: timeout) == .success
}

private struct TestSendableSampleBuffer: @unchecked Sendable {
  let value: CMSampleBuffer
}

private final class FakeSessionRecordService: SessionRecordServicing, @unchecked Sendable {
  let packageDirectory: URL
  var hasAcceptedFirstVideo = true
  private let eventLock = NSLock()
  private var storedEvents: [String] = []
  var events: [String] {
    get { eventLock.withLock { storedEvents } }
    set { eventLock.withLock { storedEvents = newValue } }
  }
  var stopCount = 0
  var abandonCount = 0
  var finishAfterCutCount = 0
  var cancelCount = 0
  var completesStopImmediately = true
  var completesCancelImmediately = true
  var recordsStopEvent = false
  private var pendingStopCompletions:
    [@MainActor @Sendable (SessionRecordFinalizationResult) -> Void] = []
  private var pendingCancelCompletions:
    [@MainActor @Sendable (SessionRecordFinalizationResult) -> Void] = []
  var startResult: Result<Void, any Error> = .success(())
  var firstVideoError: (any Error)?
  var finalizationResult: SessionRecordFinalizationResult = .finalized
  var eventHandler: (@Sendable (String) -> Void)?

  init(name: String) {
    packageDirectory = URL(fileURLWithPath: "/tmp/\(name).ldtxrecord")
  }

  func start(
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) {
    completionHandler(startResult)
  }

  func acceptFirstVideo(
    _ sampleBuffer: CMSampleBuffer,
    mainAudioFormatDescription _: CMAudioFormatDescription?
  ) throws {
    if let firstVideoError { throw firstVideoError }
    hasAcceptedFirstVideo = true
    appendEvent("first-video:\(sampleBuffer.presentationTimeStamp.seconds)")
  }

  func appendMainVideo(_ sampleBuffer: CMSampleBuffer) {
    let event = "video:\(sampleBuffer.presentationTimeStamp.seconds)"
    appendEvent(event)
    eventHandler?(event)
  }

  func appendMainAudioMix(_ sampleBuffer: CMSampleBuffer) {
    let event = "main-audio:\(sampleBuffer.presentationTimeStamp.seconds)"
    appendEvent(event)
    eventHandler?(event)
  }

  func appendInputAudio(_ sampleBuffer: CMSampleBuffer, trackID: String) {
    let event = "input:\(trackID):\(sampleBuffer.presentationTimeStamp.seconds)"
    appendEvent(event)
    eventHandler?(event)
  }

  func sealInputAudio() {}

  func stop(
    completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void
  ) {
    stopCount += 1
    if recordsStopEvent { appendEvent("stop") }
    if completesStopImmediately {
      completionHandler(finalizationResult)
    } else {
      pendingStopCompletions.append(completionHandler)
    }
  }

  func finishAfterCut(
    completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void
  ) {
    finishAfterCutCount += 1
    stop(completionHandler: completionHandler)
  }

  func stopPreservingIncompletePackage(
    completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void
  ) {
    stopCount += 1
    completionHandler(.preservedIncomplete)
  }

  func abandonAfterMediaDrainTimeout() {
    abandonCount += 1
  }

  func cancelBeforeFirstVideo(
    completionHandler: @escaping @MainActor @Sendable (SessionRecordFinalizationResult) -> Void
  ) {
    cancelCount += 1
    if completesCancelImmediately {
      completionHandler(.preservedIncomplete)
    } else {
      pendingCancelCompletions.append(completionHandler)
    }
  }

  func recordingTimelineMilliseconds() -> UInt64? { nil }
  func recordOutputStarted() {}

  private func appendEvent(_ event: String) {
    eventLock.withLock { storedEvents.append(event) }
  }

  @MainActor func completePendingStop() {
    let completions = pendingStopCompletions
    pendingStopCompletions.removeAll()
    for completion in completions { completion(finalizationResult) }
  }

  @MainActor func completePendingCancel() {
    let completions = pendingCancelCompletions
    pendingCancelCompletions.removeAll()
    for completion in completions { completion(.preservedIncomplete) }
  }
}

private final class FakeYouTubeOutputWorkspaceService: YouTubeOutputWorkspaceServicing,
  @unchecked Sendable
{
  private let lock = NSLock()
  var videoHandler: @Sendable () -> Void = {}
  private(set) var failureCount = 0
  private(set) var stopCount = 0

  func appendMainVideo(_: CMSampleBuffer) { videoHandler() }
  func appendMainAudioMix(_: CMSampleBuffer) {}

  @MainActor func failMediaDelivery(_: Error) {
    lock.withLock { failureCount += 1 }
  }

  @MainActor func stop(
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) {
    lock.withLock { stopCount += 1 }
    completionHandler(.success(()))
  }
}

private final class ImmediateTestAudioCapture: ProgramAudioCaptureStreaming, @unchecked Sendable {
  private let lock = NSLock()
  private var sampleHandler: (@Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void)?

  func startAudioCapture(
    audioDeviceID _: String?,
    failureHandler _: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    handler: @escaping @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    lock.withLock { sampleHandler = handler }
    completionHandler(.success(()))
  }

  func stop(completionHandler: @escaping @Sendable () -> Void) {
    completionHandler()
  }

  func emit(_ sampleBuffer: CMSampleBuffer) {
    let handler = lock.withLock { sampleHandler }
    DispatchQueue.global().sync { handler?(sampleBuffer, .audio) }
  }
}

private enum FakeRecordError: Error {
  case expected
}

private final class AsyncTestGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func open() {
    let waiters = lock.withLock {
      guard !isOpen else { return [CheckedContinuation<Void, Never>]() }
      isOpen = true
      let storedWaiters = self.waiters
      self.waiters.removeAll()
      return storedWaiters
    }
    for waiter in waiters { waiter.resume() }
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      lock.withLock {
        if isOpen {
          continuation.resume()
        } else {
          waiters.append(continuation)
        }
      }
    }
  }
}

private func recordSample(pts: Double, isSync: Bool = true) throws -> CMSampleBuffer {
  var timing = CMSampleTimingInfo(
    duration: CMTime(value: 1, timescale: 1_000),
    presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 1_000),
    decodeTimeStamp: .invalid)
  var sampleBuffer: CMSampleBuffer?
  let status = CMSampleBufferCreate(
    allocator: kCFAllocatorDefault,
    dataBuffer: nil,
    dataReady: true,
    makeDataReadyCallback: nil,
    refcon: nil,
    formatDescription: nil,
    sampleCount: 1,
    sampleTimingEntryCount: 1,
    sampleTimingArray: &timing,
    sampleSizeEntryCount: 0,
    sampleSizeArray: nil,
    sampleBufferOut: &sampleBuffer)
  guard status == noErr, let sampleBuffer else { throw FakeRecordError.expected }
  if !isSync {
    let attachments =
      CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
      as? [NSMutableDictionary]
    attachments?.first?[kCMSampleAttachmentKey_NotSync] = true
  }
  return sampleBuffer
}

private func recordPCMSample(pts: Double) throws -> CMSampleBuffer {
  var stream = AudioStreamBasicDescription(
    mSampleRate: 48_000,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: 8,
    mFramesPerPacket: 1,
    mBytesPerFrame: 8,
    mChannelsPerFrame: 2,
    mBitsPerChannel: 32,
    mReserved: 0)
  var format: CMAudioFormatDescription?
  let formatStatus = CMAudioFormatDescriptionCreate(
    allocator: kCFAllocatorDefault,
    asbd: &stream,
    layoutSize: 0,
    layout: nil,
    magicCookieSize: 0,
    magicCookie: nil,
    extensions: nil,
    formatDescriptionOut: &format)
  guard formatStatus == noErr, let format else { throw FakeRecordError.expected }

  let bytes = [Float32](repeating: 0, count: 2)
  var dataBuffer: CMBlockBuffer?
  let blockStatus = CMBlockBufferCreateWithMemoryBlock(
    allocator: kCFAllocatorDefault,
    memoryBlock: nil,
    blockLength: MemoryLayout<Float32>.stride * bytes.count,
    blockAllocator: nil,
    customBlockSource: nil,
    offsetToData: 0,
    dataLength: MemoryLayout<Float32>.stride * bytes.count,
    flags: 0,
    blockBufferOut: &dataBuffer)
  guard blockStatus == kCMBlockBufferNoErr, let dataBuffer else { throw FakeRecordError.expected }
  let copyStatus = bytes.withUnsafeBytes {
    CMBlockBufferReplaceDataBytes(
      with: $0.baseAddress!, blockBuffer: dataBuffer, offsetIntoDestination: 0,
      dataLength: MemoryLayout<Float32>.stride * bytes.count)
  }
  guard copyStatus == kCMBlockBufferNoErr else { throw FakeRecordError.expected }

  var timing = CMSampleTimingInfo(
    duration: CMTime(value: 1, timescale: 48_000),
    presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 48_000),
    decodeTimeStamp: .invalid)
  var sampleBuffer: CMSampleBuffer?
  let sampleStatus = CMSampleBufferCreateReady(
    allocator: kCFAllocatorDefault,
    dataBuffer: dataBuffer,
    formatDescription: format,
    sampleCount: 1,
    sampleTimingEntryCount: 1,
    sampleTimingArray: &timing,
    sampleSizeEntryCount: 0,
    sampleSizeArray: nil,
    sampleBufferOut: &sampleBuffer)
  guard sampleStatus == noErr, let sampleBuffer else { throw FakeRecordError.expected }
  return sampleBuffer
}
