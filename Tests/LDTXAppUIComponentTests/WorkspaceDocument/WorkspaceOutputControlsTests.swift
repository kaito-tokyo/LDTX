// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
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
      }
      document.isClosed = true
      let closed = WorkspaceOutputControls(stateService: document, hasSavedURL: true)
      #expect(!closed.stopEnabled && !closed.startPauseEnabled && !closed.screenshotEnabled)
    }
  }
}
