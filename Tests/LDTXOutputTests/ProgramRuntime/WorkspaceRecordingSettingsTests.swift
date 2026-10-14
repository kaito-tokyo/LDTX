// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXCapture
import LDTXProgramRuntime
import LDTXProtos
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceBundleFormat
import Testing

extension OutputTestSuite {
  @MainActor
  @Suite struct WorkspaceRecordingSettingsIntegrationTestSuite {
    @Test func archiveWriteFailureIsReportedWhenStopping() async throws {
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
      await session.stop()
      guard case .failed(let message) = session.state else {
        Issue.record("Archive write failure was not reported")
        return
      }
      #expect(!message.isEmpty)
    }

    @Test func stopWaitsForQueuedVisionArchives() async {
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

    @Test func startupKeepsCapturedSettingsUntilCleanupAndNextStart() async {
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
      let updates = LowFrequencyUpdateRegistry()
      defer { updates.shutdown() }
      let runtime = WorkspaceWindowRuntime(
        persistence: persistence, captureSessionCoordinator: capture)
      runtime.installRuntimes(
        landscape: ProgramRuntime(
          captureSessionCoordinator: capture, lowFrequencyUpdateRegistry: updates),
        portrait: ProgramRuntime(
          captureSessionCoordinator: capture, lowFrequencyUpdateRegistry: updates))
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
