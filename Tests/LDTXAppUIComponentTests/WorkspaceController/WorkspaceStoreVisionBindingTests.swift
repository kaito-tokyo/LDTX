// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("Workspace Vision Binding")
  @MainActor
  struct WorkspaceStoreVisionBindingUnitTestSuite {
    @Test func bindingFollowsIDAndDoesNotRestoreRemovedVision() throws {
      let store = WorkspaceStoreService(definition: .init(), preferences: .init())
      store.workspaceDefinition.visions = [
        WorkspaceResourceFactory.makeOcrVision(id: 2, name: "OCR", componentID: 1),
        WorkspaceResourceFactory.makeOcrVision(id: 3, name: "Other", componentID: 1),
      ]
      @Bindable var boundStore = store
      let binding = try #require($boundStore.ocrVision(internalID: 2))
      #expect($boundStore.ocrVision(internalID: 999) == nil)

      store.workspaceDefinition.visions.reverse()
      binding.wrappedValue.displayName = "Renamed"
      #expect(store.workspaceDefinition.visions[0].ocrVision.displayName == "Other")
      #expect(store.workspaceDefinition.visions[1].ocrVision.displayName == "Renamed")

      store.isOutputActive = true
      binding.wrappedValue.displayName = "Assigned during output"
      #expect(binding.wrappedValue.displayName == "Assigned during output")
      store.isOutputActive = false

      store.workspaceDefinition.visions.removeLast()
      binding.wrappedValue.displayName = "Removed"
      #expect(store.workspaceDefinition.visions.count == 1)
      #expect($boundStore.ocrVision(internalID: 2) == nil)
      #expect(binding.wrappedValue.internalID == 2)
    }
  }
}
