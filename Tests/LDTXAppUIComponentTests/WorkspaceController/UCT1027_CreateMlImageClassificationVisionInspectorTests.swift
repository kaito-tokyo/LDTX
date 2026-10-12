// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LDTXProtos
@testable import LDTXWorkspaceAppletController
@testable import LDTXWorkspaceAppletUI
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1027: Create ML Image Classifier UI", .serialized)
  @MainActor
  struct UCT1027LdtxSceneDetectorVisionIntegrationTestSuite {
    init() { _ = UIComponentTestEnvironment.documentController }

    @Test("Toolbar inference precedes Inspector and publishes the selected Vision result")
    func toolbarInference() async throws {
      let store = WorkspaceStoreService(definition: .init(), preferences: .init())
      store.workspaceDefinition.videoComponents = [
        .with {
          $0.vfxSource.internalID = 7
          $0.vfxSource.deviceWidth = 1920
          $0.vfxSource.deviceHeight = 1080
        }
      ]
      store.workspaceDefinition.visions = [
        WorkspaceResourceFactory.makeLdtxSceneDetectorVision(
          id: 2, name: "Scene", componentID: 7)
      ]
      store.inspectorSelector = .init(kind: .ldtxSceneDetectorVision, internalID: 2)
      let dispatcher = ToolbarDispatcher()
      let window = makeWorkspaceTestWindow(storeService: store, dispatcher: dispatcher)
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      let items = try #require(window.toolbar).items
      let index = try #require(
        items.firstIndex { $0.itemIdentifier.rawValue == "workspace.runInference" })
      let item = items[index]
      #expect(items[index + 1].itemIdentifier.rawValue == "workspace.toggleInspector")
      #expect(item.image != nil && !window.validateToolbarItem(item))
      store.modelURLs[2] = .some(URL(fileURLWithPath: "/tmp/model.mlmodel"))
      await settleWorkspaceToolbar(window)
      #expect(window.validateToolbarItem(item))
      try performWorkspaceToolbarAction(item)
      await settleWorkspaceToolbar(window)
      #expect(store.visionResults[2] == "Test classification")
      store.inspectorSelector = .init(kind: .workspaceCanvas)
      await settleWorkspaceToolbar(window)
      #expect(!window.validateToolbarItem(item))
    }

    @Test("ROI numerator editing uses the image size only when the denominator is unset")
    func roiNumeratorDefaults() {
      var rational = Ldtx_Workspace_V4_Rational32()
      let binding = Binding(get: { rational }, set: { rational = $0 })
      let numerator = RegionOfInterestEditor.numeratorBinding(binding, defaultDenominator: 1920)
      #expect(numerator.wrappedValue == nil && !rational.hasDen)
      numerator.wrappedValue = 320
      #expect(rational.num == 320 && rational.den == 1920)
      #expect(rational.double == 1.0 / 6)
      rational.den = 1080
      numerator.wrappedValue = 180
      #expect(rational.den == 1080)
      numerator.wrappedValue = nil
      #expect(!rational.hasNum && rational.den == 1080)
    }

    @Test("Classifier Inspector receives the resolved input size")
    func fractionDefaultsAndValidation() throws {
      let source = WorkspaceResourceFactory.makeVFXSource(id: 7, name: "Camera")
      var configuredSource = source
      configuredSource.vfxSource.deviceWidth = 1280
      configuredSource.vfxSource.deviceHeight = 720
      let videoComponents = [
        configuredSource, WorkspaceResourceFactory.makeSolidColor(id: 8, name: "Fill"),
      ]
      let vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision = .with {
        $0.videoComponentInternalID = 7
      }
      let inspector = LdtxSceneDetectorVisionInspector(
        videoComponents: videoComponents, inputSize: configuredSource.renderingSize,
        vision: .constant(vision),
        modelURL: .constant(nil), savedModelURL: nil)
      #expect(inspector.inputSize?.width == 1280)
      #expect(inspector.inputSize?.height == 720)
      let value: Ldtx_Workspace_V4_Rational32 = .with { $0.set(num: 1, den: 7) }
      let fields = RationalFractionInput.fields(for: value, defaultDenominator: 1920)
      #expect(fields.numerator == "1")
      #expect(fields.denominator == "7")

    }

    @Test("Nested ROI bindings update the Store directly")
    func immediateROIBindings() throws {
      let store = WorkspaceStoreService(definition: .init(), preferences: .init())
      store.workspaceDefinition.visions = [
        WorkspaceResourceFactory.makeLdtxSceneDetectorVision(
          id: 2, name: "Scene", componentID: 1)
      ]
      let boundStore = Bindable(wrappedValue: store)
      let binding = try #require(boundStore.ldtxSceneDetectorVision(internalID: 2))
      binding.regionOfInterest.width.num.wrappedValue = 3
      binding.regionOfInterest.width.den.wrappedValue = 4
      #expect(
        store.workspaceDefinition.visions[0].ldtxSceneDetectorVision.regionOfInterest.width
          .double
          == 0.75)
    }

    @Test("Classifier added through the sheet flow saves and reopens with its settings")
    func addAndSaveClassifier() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let document = WorkspaceDocument()
      defer { document.close() }
      let store = document.storeService
      store.workspaceDefinition.videoComponents = [
        WorkspaceResourceFactory.makeVFXSource(id: 1, name: "Source")
      ]
      var draft = WorkspaceAddDraft()
      draft.name = "Scene"
      draft.visionKind = .createMlImageClassifier
      draft.videoComponentID = 1
      let id = try WorkspaceResourceAddition.add(
        sheet: .vision, draft: draft, devices: [], storeService: store)
      #expect(
        store.inspectorSelector == .init(kind: .ldtxSceneDetectorVision, internalID: id))
      let boundStore = Bindable(wrappedValue: store)
      let binding = try #require(boundStore.ldtxSceneDetectorVision(internalID: id))
      binding.wrappedValue.regionOfInterest = .with {
        $0.x.set(num: 2, den: 10)
        $0.y.set(num: 1, den: 10)
        $0.width.set(num: 5, den: 10)
        $0.height.set(num: 6, den: 10)
      }
      let url = root.appendingPathComponent("Classifier.ldtxworkspace")
      try await saveWorkspaceDocument(document, to: url)
      let reopened = try WorkspaceDocument(contentsOf: url, ofType: "tokyo.kaito.ldtx.workspace")
      defer { reopened.close() }
      #expect(
        reopened.storeService.workspaceDefinition.visions == store.workspaceDefinition.visions)
      #expect(binding.wrappedValue.videoComponentInternalID == 1)
      #expect(binding.wrappedValue.triggers.first?.intervalTrigger.intervalSeconds.double == 5)
    }

    @Test("Invalid classifier ROI is rejected; bindings do not overwrite a different Vision")
    func rejectInvalidRegionAndRemovedBinding() throws {
      let store = WorkspaceStoreService(definition: .init(), preferences: .init())
      store.workspaceDefinition.visions = [
        WorkspaceResourceFactory.makeLdtxSceneDetectorVision(
          id: 2, name: "Scene", componentID: 1)
      ]
      let boundStore = Bindable(wrappedValue: store)
      let binding = try #require(boundStore.ldtxSceneDetectorVision(internalID: 2))
      let invalidRegion: Ldtx_Workspace_V4_VisionRegionOfInterest = .with {
        $0.x.set(num: 8, den: 10)
        $0.y.set(num: 0, den: 10)
        $0.width.set(num: 5, den: 10)
        $0.height.set(num: 10, den: 10)
      }
      #expect(throws: (any Error).self) {
        try WorkspaceV4IntegrityValidator.validateRegionOfInterest(invalidRegion)
      }
      store.workspaceDefinition.visions = [
        WorkspaceResourceFactory.makeOcrVision(id: 2, name: "OCR", componentID: 1)
      ]
      binding.wrappedValue.displayName = "Removed classifier"
      #expect(store.workspaceDefinition.visions.first?.ocrVision.displayName == "OCR")
      #expect(boundStore.ldtxSceneDetectorVision(internalID: 2) == nil)
    }
  }
}
