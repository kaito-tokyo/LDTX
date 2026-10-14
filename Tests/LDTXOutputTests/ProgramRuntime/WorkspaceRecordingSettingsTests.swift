// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

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
