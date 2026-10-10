// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
@testable import LDTXWorkspaceAppletUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1025: Invalid ROI prevents leaving", .serialized)
  @MainActor
  struct UCT1025OcrVisionInspectorIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    private func makeStore() -> WorkspaceStoreService {
      let store = WorkspaceStoreService(definition: .init(), preferences: .init())
      var vision = WorkspaceResourceFactory.makeOcrVision(id: 2, name: "OCR", componentID: 1)
        .ocrVision
      vision.regionOfInterest = .with {
        $0.width = .with { $0.set(num: 1, den: 1) }
        $0.height = .with { $0.set(num: 1, den: 1) }
      }
      store.workspaceDefinition.visions = [.with { $0.ocrVision = vision }]
      store.inspectorSelector = .init(kind: .ocrVision, internalID: 2)
      return store
    }

    @Test("UCT-1025.1: Invalid drafts block navigation without corrupting the model")
    func invalidDraftBlocksNavigation() throws {
      let storeEditingState = WorkspaceEditingState()
      let store = makeStore()
      let original = store.workspaceDefinition
      var x = "0"
      let width = "1"
      let validatorID = UUID()
      storeEditingState.registerInspectorEditValidator(id: validatorID, hasChanges: { x != "0" }) {
        _ = try OcrVisionInspector.validatedRegion(x: x, y: "0", width: width, height: "1")
      }
      defer { storeEditingState.removeInspectorEditValidator(id: validatorID) }
      var errors: [String] = []
      storeEditingState.inputValidationErrorHandler = { errors.append($0.localizedDescription) }
      for text in ["-0.1", "not a number", "2"] {
        x = text
        WorkspaceSidebar.select(
          .init(kind: .workspacePrograms), storeService: store, editingState: storeEditingState)
        #expect(store.inspectorSelector == .init(kind: .ocrVision, internalID: 2))
        #expect(x == text)
        #expect(store.workspaceDefinition == original)
        #expect(throws: (any Error).self) { try storeEditingState.validateInspectorEdits() }
      }
      #expect(errors.isEmpty)
    }

    @Test("UCT-1025.2: Correcting the complete rectangle allows navigation")
    func correctionAllowsNavigation() throws {
      let storeEditingState = WorkspaceEditingState()
      let store = makeStore()
      var x = "0"
      var width = "10"
      let validatorID = UUID()
      storeEditingState.registerInspectorEditValidator(id: validatorID) {
        _ = try OcrVisionInspector.validatedRegion(
          x: x, y: "0", width: width, height: "10", xDenominator: "10", yDenominator: "10",
          widthDenominator: "10", heightDenominator: "10")
      }
      defer { storeEditingState.removeInspectorEditValidator(id: validatorID) }
      x = "8"
      #expect(throws: (any Error).self) { try storeEditingState.validateInspectorEdits() }
      width = "1"
      store.workspaceDefinition.visions[0].ocrVision.regionOfInterest =
        try OcrVisionInspector.validatedRegion(
          x: x, y: "0", width: width, height: "10", xDenominator: "10", yDenominator: "10",
          widthDenominator: "10", heightDenominator: "10")
      try storeEditingState.validateInspectorEdits()
      #expect(store.workspaceDefinition.visions[0].ocrVision.regionOfInterest.x.double == 0.8)
      #expect(store.workspaceDefinition.visions[0].ocrVision.regionOfInterest.width.double == 0.1)
      WorkspaceSidebar.select(
        .init(kind: .workspacePrograms), storeService: store, editingState: storeEditingState)
      #expect(store.inspectorSelector == .init(kind: .workspacePrograms))
    }
  }
}
