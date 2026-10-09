// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
@testable import LDTXWorkspaceAppletController
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1027: Create ML Image Classifier UI", .serialized)
  @MainActor
  struct UCT1027CreateMlImageClassifierVisionIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    @Test("Fraction fields default to Canvas dimensions without rounding stored values")
    func fractionDefaultsAndValidation() throws {
      let store = WorkspaceStoreService(definition: .init(), preferences: .init())
      let inspector = CreateMlImageClassifierVisionInspector(
        storeService: store, vision: .constant(.init()))
      #expect(inspector.inputs == [0, 1920, 0, 1080, 1920, 1920, 1080, 1080])
      let value: Ldtx_Workspace_V4_Rational32 = .with { $0.set(num: 1, den: 7) }
      let fields = RationalFractionInput.fields(for: value, defaultDenominator: 1920)
      #expect(fields.numerator == "1")
      #expect(fields.denominator == "7")
      for denominator: UInt32 in [0] {
        #expect(throws: (any Error).self) {
          try CreateMlImageClassifierVisionInspector.validatedRegion(
            x: 0, y: 0, width: 1920, height: 1080,
            xDenominator: denominator, yDenominator: 1080,
            widthDenominator: 1920, heightDenominator: 1080)
        }
      }
    }

    @Test("Blank nullable ROI fields cannot be applied")
    func blankFields() {
      #expect(throws: (any Error).self) {
        try CreateMlImageClassifierVisionInspector.validatedRegion(
          x: nil, y: 0, width: 1, height: 1)
      }
      #expect(throws: (any Error).self) {
        try CreateMlImageClassifierVisionInspector.validatedRegion(
          x: 0, y: 0, width: 1, height: 1, xDenominator: nil)
      }
    }

    @Test("Integer fractions preserve coordinates and reject invalid ROI bounds")
    func pixelCoordinates() throws {
      for region in [
        try CreateMlImageClassifierVisionInspector.validatedRegion(
          x: 320, y: 180, width: 640, height: 360, xDenominator: 1280,
          yDenominator: 720, widthDenominator: 1280, heightDenominator: 720),
        try OcrVisionInspector.validatedRegion(
          x: "320", y: "180", width: "640", height: "360", xDenominator: "1280",
          yDenominator: "720", widthDenominator: "1280", heightDenominator: "720"),
      ] {
        #expect(region.x.double == 0.25)
        #expect(region.y.double == 0.25)
        #expect(RationalFormatStyle(multiplier: 1280).format(region.x) == "320")
        #expect(RationalFormatStyle(multiplier: 720).format(region.y) == "180")
      }
      for x: Int32 in [-1, 1281] {
        #expect(throws: (any Error).self) {
          try CreateMlImageClassifierVisionInspector.validatedRegion(
            x: x, y: 0, width: 128, height: 720, xDenominator: 1280, yDenominator: 720,
            widthDenominator: 1280, heightDenominator: 720)
        }
      }
    }

    @Test("Classifier added through the sheet flow saves and reopens with its settings")
    func addAndSaveClassifier() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let document = WorkspaceDocument()
      defer { document.close() }
      let store = document.storeService
      store.definition.videoComponents = [
        WorkspaceResourceFactory.makeSolidColor(id: 1, name: "Source")
      ]
      var draft = WorkspaceAddDraft()
      draft.name = "Scene"
      draft.visionKind = .createMlImageClassifier
      draft.videoComponentID = 1
      let id = try WorkspaceResourceAddition.add(
        sheet: .vision, draft: draft, devices: [], storeService: store)
      #expect(
        store.inspectorSelector == .init(kind: .createMlImageClassifierVision, internalID: id))
      let boundStore = Bindable(wrappedValue: store)
      let binding = try #require(boundStore.createMlImageClassifierVision(internalID: id))
      binding.wrappedValue.regionOfInterest =
        try CreateMlImageClassifierVisionInspector.validatedRegion(
          x: 2, y: 1, width: 5, height: 6, xDenominator: 10, yDenominator: 10,
          widthDenominator: 10, heightDenominator: 10)
      let url = root.appendingPathComponent("Classifier.ldtxworkspace")
      try await saveWorkspaceDocument(document, to: url)
      let reopened = try WorkspaceDocument(contentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
      defer { reopened.close() }
      #expect(reopened.storeService.definition.visions == store.definition.visions)
      #expect(binding.wrappedValue.videoComponentInternalID == 1)
      #expect(binding.wrappedValue.triggers.first?.intervalTrigger.intervalSeconds.double == 5)
    }

    @Test("Invalid classifier ROI is rejected; bindings do not overwrite a different Vision")
    func rejectInvalidRegionAndRemovedBinding() throws {
      let store = WorkspaceStoreService(definition: .init(), preferences: .init())
      store.definition.visions = [
        WorkspaceResourceFactory.makeCreateMlImageClassifierVision(
          id: 2, name: "Scene", componentID: 1)
      ]
      let boundStore = Bindable(wrappedValue: store)
      let binding = try #require(boundStore.createMlImageClassifierVision(internalID: 2))
      #expect(throws: (any Error).self) {
        try CreateMlImageClassifierVisionInspector.validatedRegion(
          x: 8, y: 0, width: 5, height: 10, xDenominator: 10, yDenominator: 10,
          widthDenominator: 10, heightDenominator: 10)
      }
      store.definition.visions = [
        WorkspaceResourceFactory.makeOcrVision(id: 2, name: "OCR", componentID: 1)
      ]
      binding.wrappedValue.displayName = "Removed classifier"
      #expect(store.definition.visions.first?.ocrVision.displayName == "OCR")
      #expect(boundStore.createMlImageClassifierVision(internalID: 2) == nil)
    }
  }
}
