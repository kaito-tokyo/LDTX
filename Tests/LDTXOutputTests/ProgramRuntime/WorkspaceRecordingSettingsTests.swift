// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXCapture
import LDTXCorelibs
import LDTXProgramRuntime
@testable import LDTXWorkspaceAppletService
import Testing

extension OutputTestSuite {
  @MainActor
  @Suite struct WorkspaceRecordingSettingsIntegrationTestSuite {
    @Test(
      "LUB-1070: Program reconfiguration joins existing native failure drain",
      .timeLimit(.minutes(1)))
    func programReconfigurationJoinsExistingNativeFailureDrain() async throws {
      var workspace = WorkspaceV4Bundle(definition: .init(), preferences: .init())
      let persistence = WorkspaceV4PersistenceCoordinator(
        workspaceSnapshot: { workspace }, replaceWorkspace: { workspace = $0 })
      let runtime = WorkspaceWindowRuntime(
        persistence: persistence, captureSessionCoordinator: WorkspaceCaptureSessionCoordinator())
      defer { runtime.shutdown() }
      let archive = DispatchQueue(label: "test.switch-failure-drain")
      let release = DispatchSemaphore(value: 0)
      defer { release.signal() }
      archive.async { _ = release.wait(timeout: .now() + 5) }
      let session = WorkspaceV4RecordingSession(windowRuntime: runtime, visionArchiveQueue: archive)
      session.state = .recording
      let failure = Task { await session.fail(NSError(domain: "native-fault", code: 5)) }
      for _ in 0..<1000 where session.state != .stopping { await Task.yield() }
      try #require(session.state == .stopping)
      var returned = false
      let switching = Task {
        try await session.reconfigureProgramOutputAndWait()
        returned = true
      }
      for _ in 0..<100 { await Task.yield() }
      #expect(!returned)
      release.signal()
      await failure.value
      try await switching.value
      #expect(returned)
    }

    @Test(
      "LUB-1070: Stop result distinguishes new failure with the same message from retained failure",
      .timeLimit(.minutes(1)))
    func stopResultDistinguishesNewFailureWithTheSameMessageFromRetainedFailure() async throws {
      var workspace = WorkspaceV4Bundle(definition: .init(), preferences: .init())
      let persistence = WorkspaceV4PersistenceCoordinator(
        workspaceSnapshot: { workspace }, replaceWorkspace: { workspace = $0 })
      let runtime = WorkspaceWindowRuntime(
        persistence: persistence, captureSessionCoordinator: WorkspaceCaptureSessionCoordinator())
      defer { runtime.shutdown() }
      let archive = DispatchQueue(label: "test.current-stop-error")
      let release = DispatchSemaphore(value: 0)
      defer { release.signal() }
      archive.async { _ = release.wait(timeout: .now() + 5) }
      let session = WorkspaceV4RecordingSession(windowRuntime: runtime, visionArchiveQueue: archive)
      session.state = .failed("Same message")
      let stopping = Task { await session.stopWithResult() }
      for _ in 0..<1_000 where session.state != .stopping { await Task.yield() }
      try #require(session.state == .stopping)
      await session.fail(
        NSError(
          domain: "current-stop", code: 94,
          userInfo: [NSLocalizedDescriptionKey: "Same message"]))
      release.signal()
      guard case .failure(let error) = await stopping.value else {
        Issue.record("A new failure must not be hidden by equal error text")
        return
      }
      #expect(error.code == 94)
      #expect(session.state == .failed("Same message"))
      guard case .success = await session.stopWithResult() else {
        Issue.record("A retained error must not fail the next stop operation")
        return
      }
      #expect(session.state == .failed("Same message"))
    }

    @Test("LUB-1070: Stop joins existing pause through archive drain", .timeLimit(.minutes(1)))
    func stopJoinsExistingPauseThroughArchiveDrain() async throws {
      var workspace = WorkspaceV4Bundle(definition: .init(), preferences: .init())
      let persistence = WorkspaceV4PersistenceCoordinator(
        workspaceSnapshot: { workspace }, replaceWorkspace: { workspace = $0 })
      let runtime = WorkspaceWindowRuntime(
        persistence: persistence, captureSessionCoordinator: WorkspaceCaptureSessionCoordinator())
      defer { runtime.shutdown() }
      let archive = DispatchQueue(label: "test.pause-archive")
      let release = DispatchSemaphore(value: 0)
      defer { release.signal() }
      archive.async { _ = release.wait(timeout: .now() + 5) }
      let session = WorkspaceV4RecordingSession(windowRuntime: runtime, visionArchiveQueue: archive)
      session.state = .recording
      let pausing = Task { await session.pause() }
      for _ in 0..<1_000 where session.state != .pausing { await Task.yield() }
      try #require(session.state == .pausing)
      let stopping = Task { await session.stop() }
      await Task.yield()
      #expect(session.state == .pausing)
      release.signal()
      await pausing.value
      await stopping.value
      #expect(session.state == .idle)
    }

    @Test(
      "LUB-1070: One workspace archive drain does not block another workspace stop",
      .timeLimit(.minutes(1)))
    func oneWorkspaceArchiveDrainDoesNotBlockAnotherWorkspaceStop() async throws {
      var workspace = WorkspaceV4Bundle(definition: .init(), preferences: .init())
      let firstPersistence = WorkspaceV4PersistenceCoordinator(
        workspaceSnapshot: { workspace }, replaceWorkspace: { workspace = $0 })
      let secondPersistence = WorkspaceV4PersistenceCoordinator(
        workspaceSnapshot: { workspace }, replaceWorkspace: { workspace = $0 })
      let firstRuntime = WorkspaceWindowRuntime(
        persistence: firstPersistence,
        captureSessionCoordinator: WorkspaceCaptureSessionCoordinator())
      let secondRuntime = WorkspaceWindowRuntime(
        persistence: secondPersistence,
        captureSessionCoordinator: WorkspaceCaptureSessionCoordinator())
      defer {
        firstRuntime.shutdown()
        secondRuntime.shutdown()
      }
      let archive = DispatchQueue(label: "test.workspace-archive")
      let release = DispatchSemaphore(value: 0)
      defer { release.signal() }
      archive.async { _ = release.wait(timeout: .now() + 5) }
      let first = WorkspaceV4RecordingSession(
        windowRuntime: firstRuntime, visionArchiveQueue: archive)
      let second = WorkspaceV4RecordingSession(windowRuntime: secondRuntime)
      first.state = .recording
      second.state = .recording
      let stopping = Task { await first.stop() }
      for _ in 0..<1_000 where first.state != .stopping { await Task.yield() }
      try #require(first.state == .stopping)
      await second.stop()
      #expect(second.state == .idle)
      #expect(first.state == .stopping)
      release.signal()
      await stopping.value
      #expect(first.state == .idle)
    }

    @Test("LUB-1070: Archive write failure is reported when stopping")
    func archiveWriteFailureIsReportedWhenStopping() async throws {
      var workspace = WorkspaceV4Bundle(definition: .init(), preferences: .init())
      let persistence = WorkspaceV4PersistenceCoordinator(
        workspaceSnapshot: { workspace }, replaceWorkspace: { workspace = $0 })
      let runtime = WorkspaceWindowRuntime(
        persistence: persistence, captureSessionCoordinator: WorkspaceCaptureSessionCoordinator())
      defer { runtime.shutdown() }
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try Data().write(to: url)
      defer { try? FileManager.default.removeItem(at: url) }
      let session = WorkspaceV4RecordingSession(windowRuntime: runtime)
      session.state = .recording
      session.enqueueVisionArchive(
        internalID: 1, image: CIImage.empty(), output: "Result", timelineMilliseconds: 0,
        packageDirectory: url)
      let result = await session.stopWithResult()
      guard case .failure = result else {
        Issue.record("Expected current archive failure")
        return
      }
      guard case .failed(let message) = session.state else {
        Issue.record("Archive write failure was not reported")
        return
      }
      #expect(!message.isEmpty)
      guard case .success = await session.stopWithResult() else {
        Issue.record("Prior finalization failure must not become a new stop failure")
        return
      }
      #expect(session.state == .failed(message))
    }

    @Test("LUB-1070: Stop waits for queued vision archives") func stopWaitsForQueuedVisionArchives()
      async
    {
      var workspace = WorkspaceV4Bundle(definition: .init(), preferences: .init())
      let persistence = WorkspaceV4PersistenceCoordinator(
        workspaceSnapshot: { workspace }, replaceWorkspace: { workspace = $0 })
      let runtime = WorkspaceWindowRuntime(
        persistence: persistence, captureSessionCoordinator: WorkspaceCaptureSessionCoordinator())
      defer { runtime.shutdown() }
      let queue = DispatchQueue(label: "test.vision-archive")
      let release = DispatchSemaphore(value: 0)
      queue.async { release.wait() }
      let session = WorkspaceV4RecordingSession(windowRuntime: runtime, visionArchiveQueue: queue)
      session.state = .recording
      runtime.visionArchiveHandler = { _, _, _ in }
      let stopping = Task { await session.stop() }
      for _ in 0..<100 where session.state != .stopping { await Task.yield() }
      #expect(session.state == .stopping)
      for _ in 0..<100 where runtime.visionArchiveHandler != nil { await Task.yield() }
      #expect(runtime.visionArchiveHandler == nil)
      #expect(session.state == .stopping)
      release.signal()
      await stopping.value
      #expect(session.state == .idle)
    }

    @Test("LUB-1029: Startup keeps captured settings until cleanup and next start")
    func startupKeepsCapturedSettingsUntilCleanupAndNextStart() async {
      var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
      definition.displayName = "Test"
      var program = Ldtx_Workspace_V4_ProgramDefinition()
      program.internalID = 1
      program.displayName = "Program"
      definition.programs = [program]
      var workspace = WorkspaceV4Bundle(definition: definition, preferences: .init())
      workspace.outputSettings.youtubeEnabled = true
      workspace.outputSettings.youtubeSettings.ingestMode = .landscapeRtmps
      let original = workspace.outputSettings
      let persistence = WorkspaceV4PersistenceCoordinator(
        workspaceSnapshot: { workspace }, replaceWorkspace: { workspace = $0 })
      let capture = WorkspaceCaptureSessionCoordinator()
      let runtime = WorkspaceWindowRuntime(
        persistence: persistence, captureSessionCoordinator: capture)
      runtime.installRuntimes(
        landscape: ProgramRuntime(
          captureSessionCoordinator: capture),
        portrait: ProgramRuntime(
          captureSessionCoordinator: capture))
      defer { runtime.shutdown() }
      let session = WorkspaceV4RecordingSession(
        windowRuntime: runtime,
        streamKeyConfigurations: { throw CocoaError(.userCancelled) })
      var changed = false
      session.stateDidChange = { state in
        if state == .starting, !changed {
          changed = true
          workspace.outputSettings.youtubeSettings.ingestMode = .portraitRtmps
        }
      }
      await session.start()
      #expect(changed)
      #expect(session.sessionOutputSettings == original)
      #expect(runtime.workspace.outputSettings.youtubeSettings.ingestMode == .portraitRtmps)
      await session.stop()
      #expect(session.sessionOutputSettings == nil)
      await session.start()
      #expect(session.sessionOutputSettings == workspace.outputSettings)
      await session.stop()
      #expect(session.sessionOutputSettings == nil)
    }
  }
}
