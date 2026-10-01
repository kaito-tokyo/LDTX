// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletUI
import Testing

@Suite
@MainActor
struct WorkspaceOutputStateSystemTestSuite {
  @Test func storesOutputStatusForWorkspaceUI() {
    let uiState = WorkspaceUIState(definition: .init(), preferences: .init())

    uiState.isOutputActive = true
    uiState.isLocalRecording = true
    uiState.outputFailureMessage = nil

    #expect(uiState.isOutputActive)
    #expect(uiState.isLocalRecording)
    #expect(uiState.outputFailureMessage == nil)

    uiState.isOutputActive = false
    uiState.isLocalRecording = false
    uiState.outputFailureMessage = "Output failed."

    #expect(!uiState.isOutputActive)
    #expect(!uiState.isLocalRecording)
    #expect(uiState.outputFailureMessage == "Output failed.")
  }
}
