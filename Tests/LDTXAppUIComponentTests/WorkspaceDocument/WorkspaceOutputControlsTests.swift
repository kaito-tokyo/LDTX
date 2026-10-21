// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
  @Suite @MainActor
  struct WorkspaceActionIntegrationTestSuite {
    @Test func failedAndClosedCaptureDoNotPublishSuccess() async {
      let document = WorkspaceDocument()
      let coordinator = WorkspaceAppletCoordinator(document: document)
      var notifications = 0
      coordinator.screenshotsDidSave = { _ in notifications += 1 }
      document.outputFailureMessage = "Existing output failure"
      #expect(coordinator.actionState(.captureScreenshots).isEnabled)
      let failed = await coordinator.perform(.captureScreenshots)
      #expect(failed == nil)
      #expect(notifications == 0)
      #expect(document.outputFailureMessage == "Existing output failure")
      await coordinator.shutdown()
      let errorCount = document.operationErrors.count
      for action in WorkspaceAction.allCases {
        #expect(!coordinator.actionState(action).isEnabled)
        let result = await coordinator.perform(action)
        #expect(result == nil)
      }
      #expect(document.operationErrors.count == errorCount)
      #expect(notifications == 0)
    }
  }

  @Suite @MainActor
  struct WorkspaceOutputControlsUnitTestSuite {
    @Test func savedUnsavedTransitionAndClosedAdmission() {
      let document = WorkspaceDocument()
      let states: [WorkspaceRecordingState] = [
        .idle, .starting, .recording, .pausing, .paused, .stopping, .failed("failure"),
      ]
      for state in states {
        document.recordingState = state
        let saved = WorkspaceOutputControls(stateService: document, hasSavedURL: true)
        let unsaved = WorkspaceOutputControls(stateService: document, hasSavedURL: false)
        #expect(saved.showsPause == (state == .recording))
        #expect(saved.stopEnabled == state.canStop)
        #expect(saved.startPauseEnabled == (state.canStart || state == .recording))
        #expect(unsaved.startPauseEnabled == (state == .recording))
        #expect(saved.screenshotEnabled)
        #expect(saved.state(for: .stopOutput, hasRecording: true).isEnabled == state.canStop)
        #expect(
          saved.state(for: .startPauseOutput, hasRecording: true).isEnabled
            == (state.canStart || state == .recording))
        #expect(saved.state(for: .captureScreenshots, hasRecording: false).isEnabled)
        #expect(saved.state(for: .showRecordingInFinder, hasRecording: true).isEnabled)
        #expect(!saved.state(for: .showRecordingInFinder, hasRecording: false).isEnabled)
        let closing = WorkspaceOutputControls(
          stateService: document, hasSavedURL: true, isClosing: true)
        #expect(!document.isClosed)
        #expect(!closing.stopEnabled && !closing.startPauseEnabled && !closing.screenshotEnabled)
        for action in WorkspaceAction.allCases {
          #expect(!closing.state(for: action, hasRecording: true).isEnabled)
        }
      }
      document.isClosed = true
      let closed = WorkspaceOutputControls(stateService: document, hasSavedURL: true)
      #expect(!closed.stopEnabled && !closed.startPauseEnabled && !closed.screenshotEnabled)
      for action in WorkspaceAction.allCases {
        #expect(!closed.state(for: action, hasRecording: true).isEnabled)
      }
    }
  }
}
