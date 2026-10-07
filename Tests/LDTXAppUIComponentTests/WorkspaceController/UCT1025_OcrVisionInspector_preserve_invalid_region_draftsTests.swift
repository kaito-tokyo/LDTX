// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

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
        $0.widthRational = .with { $0.set(num: 1, den: 1) }
        $0.heightRational = .with { $0.set(num: 1, den: 1) }
      }
      store.definition.visions = [.with { $0.ocrVision = vision }]
      store.inspectorSelector = .init(kind: .ocrVision, internalID: 2)
      return store
    }

    @Test("UCT-1025.1: Invalid drafts block navigation without corrupting the model")
    func invalidDraftBlocksNavigation() throws {
      let store = makeStore()
      let original = store.definition
      var errors: [String] = []
      store.errorHandler = { errors.append($0.localizedDescription) }
      for text in ["-0.1", "not a number", "2"] {
        store.editOcrRegion(internalID: 2, field: "X", text: text)
        store.inspectorSelector = .init(kind: .workspacePrograms)
        #expect(store.inspectorSelector == .init(kind: .ocrVision, internalID: 2))
        #expect(store.ocrRegionDrafts[2]?["X"] == text)
        #expect(store.definition == original)
        #expect(throws: (any Error).self) { try store.validateInspectorEdits() }
        #expect(throws: (any Error).self) { try store.validateForSaving() }
      }
      #expect(errors.count == 3)
    }

    @Test("UCT-1025.2: Correcting the complete rectangle allows navigation")
    func correctionAllowsNavigation() throws {
      let store = makeStore()
      store.editOcrRegion(internalID: 2, field: "X", text: "0.8")
      #expect(throws: (any Error).self) { try store.validateInspectorEdits() }
      store.editOcrRegion(internalID: 2, field: "Width", text: "0.1")
      try store.validateInspectorEdits()
      #expect(store.definition.visions[0].ocrVision.regionOfInterest.xRational.double == 0.8)
      #expect(store.definition.visions[0].ocrVision.regionOfInterest.widthRational.double == 0.1)
      store.inspectorSelector = .init(kind: .workspacePrograms)
      #expect(store.inspectorSelector == .init(kind: .workspacePrograms))
    }
  }
}
