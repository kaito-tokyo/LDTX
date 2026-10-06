// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
  @Suite
  @MainActor
  struct WorkspaceOutputStateUnitTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    @Test func storesOutputStatusForWorkspaceUI() {
      let storeService = WorkspaceStoreService(definition: .init(), preferences: .init())

      storeService.isOutputActive = true
      storeService.isLocalRecording = true
      storeService.outputFailureMessage = nil

      #expect(storeService.isOutputActive)
      #expect(storeService.isLocalRecording)
      #expect(storeService.outputFailureMessage == nil)

      storeService.isOutputActive = false
      storeService.isLocalRecording = false
      storeService.outputFailureMessage = "Output failed."

      #expect(!storeService.isOutputActive)
      #expect(!storeService.isLocalRecording)
      #expect(storeService.outputFailureMessage == "Output failed.")
    }
  }
}
