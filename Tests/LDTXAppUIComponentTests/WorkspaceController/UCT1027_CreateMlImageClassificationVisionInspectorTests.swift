// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LDTXProtos
@testable import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletModel
@testable import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import SwiftUI
import Testing

extension AppUIComponentTestSuite {
  @Suite("UCT-1027: Create ML Image Classifier UI", .serialized)
  @MainActor
  struct UCT1027LdtxSceneDetectorVisionIntegrationTestSuite {
    @Test("LUB-1048: Model information uses persisted copy")
    func modelInformationUsesPersistedCopy() {
      let source = URL(fileURLWithPath: "/missing/source.mlpackage")
      let embedded = URL(fileURLWithPath: "/workspace/VisionModels/3/source.mlpackage")
      var inspector = LdtxSceneDetectorVisionInspector(
        videoComponents: [], inputSize: nil, vision: .constant(.init()),
        modelURL: .constant(source), persistedModelURL: embedded)
      #expect(inspector.modelInformationURL == embedded)
      inspector.persistedModelURL = nil
      #expect(inspector.modelInformationURL == source)
    }

    @Test("LUB-1048: Classifier addition rejects zero sized input")
    func classifierAdditionRejectsZeroSizedInput() throws {
      let store = WorkspaceDocument(definition: .init(), preferences: .init())
      store.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents = [
          WorkspaceResourceFactory.makeVFXSource(id: 1, name: "Source")
        ]
      }
      var draft = WorkspaceAddDraft()
      draft.name = "Scene"
      draft.visionKind = .createMlImageClassifier
      draft.videoComponentID = 1
      #expect(throws: (any Error).self) {
        try WorkspaceResourceAddition.add(
          sheet: .vision, draft: draft, devices: [], stateService: store)
      }
      #expect(store.workspaceDefinition.visions.isEmpty)
      store.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents[0].vfxSource.deviceWidth = 1920
      }
      store.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents[0].vfxSource.deviceHeight = 1080
      }
      _ = try WorkspaceResourceAddition.add(
        sheet: .vision, draft: draft, devices: [], stateService: store)
      #expect(store.workspaceDefinition.visions.count == 1)
    }

    @Test("LUB-1048: Revert validation follows output state")
    func revertValidationFollowsOutputState() {
      let store = WorkspaceDocument(definition: .init(), preferences: .init())
      let window = makeWorkspaceTestWindow(stateService: store, dispatcher: ToolbarDispatcher())
      defer { window.close() }
      let responder = WorkspaceDocumentActions(stateService: store)
      for selector in [
        #selector(WorkspaceDocumentActions.revertDocumentToSaved(_:)),
        #selector(WorkspaceDocumentActions.browseDocumentVersions(_:)),
      ] {
        let item = NSMenuItem(title: "Revert", action: selector, keyEquivalent: "")
        for state: WorkspaceRecordingState in [.starting, .recording, .pausing, .stopping] {
          store.recordingState = state
          store.isOutputActive = state.isOutputActive
          #expect(!responder.validateUserInterfaceItem(item))
        }
        store.recordingState = .idle
        store.isOutputActive = false
        #expect(responder.validateUserInterfaceItem(item))
      }
    }

    init() { _ = UIComponentTestEnvironment.documentController }

    @Test("LUB-1048: Toolbar inference precedes Inspector and publishes the selected Vision result")
    func toolbarInference() async throws {
      let store = WorkspaceDocument(definition: .init(), preferences: .init())
      store.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents = [
          .with {
            $0.vfxSource.internalID = 7
            $0.vfxSource.deviceWidth = 1920
            $0.vfxSource.deviceHeight = 1080
          }
        ]
      }
      store.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.visions = [
          WorkspaceResourceFactory.makeLdtxSceneDetectorVision(
            id: 2, name: "Scene", componentID: 7)
        ]
      }
      store.inspectorSelector = .init(kind: .ldtxSceneDetectorVision, internalID: 2)
      let dispatcher = ToolbarDispatcher()
      let context = InferenceDocumentContext()
      let window = makeWorkspaceTestWindow(
        stateService: store, dispatcher: dispatcher, documentContext: context)
      defer { window.close() }
      await settleWorkspaceToolbar(window)
      let items = try #require(window.toolbar).items
      let index = try #require(
        items.firstIndex { $0.itemIdentifier.rawValue == "workspace.runInference" })
      let item = items[index]
      #expect(items[index + 1].itemIdentifier.rawValue == "workspace.toggleInspector")
      #expect(item.menuFormRepresentation != nil && !window.validateToolbarItem(item))
      store.setVisionModelURL(URL(fileURLWithPath: "/tmp/model.mlmodel"), for: 2, undoManager: nil)
      await settleWorkspaceToolbar(window)
      #expect(!window.validateToolbarItem(item))
      context.adopt(store)
      // Source and persisted URLs differ, but both refer to the same model ID.
      store.editWorkspace(undoManager: nil) { workspace in
        workspace.visionModels[5] = URL(fileURLWithPath: "/tmp/model.mlmodel")
      }
      await settleWorkspaceToolbar(window)
      #expect(window.validateToolbarItem(item))
      try performWorkspaceToolbarAction(item)
      await settleWorkspaceToolbar(window)
      #expect(store.visionResults[2] == "Test classification")
      store.inspectorSelector = .init(kind: .workspaceCanvas)
      await settleWorkspaceToolbar(window)
      #expect(!window.validateToolbarItem(item))
    }

    @Test(
      "LUB-1048: Inference discards obsolete results and failures",
      arguments: ["model", "input", "roi", "failure"])
    func discardObsoleteInference(change: String) async throws {
      let store = WorkspaceDocument(definition: .init(), preferences: .init())
      store.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents = [7, 9].map { id in
          .with {
            $0.vfxSource.internalID = Int64(id)
            $0.vfxSource.deviceWidth = 1920
            $0.vfxSource.deviceHeight = 1080
          }
        }
      }
      store.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.visions = [
          WorkspaceResourceFactory.makeLdtxSceneDetectorVision(id: 2, name: "Scene", componentID: 7)
        ]
      }
      store.inspectorSelector = .init(kind: .ldtxSceneDetectorVision, internalID: 2)
      store.setVisionModelURL(URL(fileURLWithPath: "/tmp/model.mlmodel"), for: 2, undoManager: nil)
      let dispatcher = ToolbarDispatcher()
      let context = InferenceDocumentContext()
      context.adopt(store)
      var completion: CheckedContinuation<String, any Error>?
      dispatcher.classificationHandler = {
        try await withCheckedThrowingContinuation { completion = $0 }
      }
      let window = makeWorkspaceTestWindow(
        stateService: store, dispatcher: dispatcher, documentContext: context)
      defer { window.close() }
      window.runInference()
      await settleWorkspaceToolbar(window)
      let pending = try #require(completion)
      switch change {
      case "input":
        store.editWorkspace(undoManager: nil) { workspace in
          workspace.definition.visions[0].ldtxSceneDetectorVision.videoComponentInternalID = 9
        }
      case "roi":
        store.editWorkspace(undoManager: nil) { workspace in
          workspace.definition.visions[0].ldtxSceneDetectorVision.regionOfInterest.x.set(
            num: 1, den: 10)
        }
      default:
        store.setVisionModelURL(
          URL(fileURLWithPath: "/tmp/replacement.mlmodel"), for: 2, undoManager: nil)
      }
      if change == "failure" {
        pending.resume(throwing: CocoaError(.fileReadUnknown))
      } else {
        pending.resume(returning: "Obsolete result")
      }
      await settleWorkspaceToolbar(window)
      #expect(store.visionResults[2] == nil)
      #expect(store.visionFailureMessages[2] == nil)
    }

    @Test("LUB-1048: ROI editing preserves absent fields for image-size defaults")
    func roiNumeratorDefaults() throws {
      var rational = Ldtx_Workspace_V4_Rational32()
      let binding = Binding(get: { rational }, set: { rational = $0 })
      let numerator = RegionOfInterestEditor.numeratorBinding(binding)
      #expect(numerator.wrappedValue == nil && !rational.hasDen)
      numerator.wrappedValue = 320
      #expect(rational.num == 320 && !rational.hasDen)
      var region = Ldtx_Workspace_V4_VisionRegionOfInterest()
      region.x = rational
      #expect(try region.resolved(inputSize: (1920, 1080)).x.double == 1.0 / 6)
      rational.den = 1080
      numerator.wrappedValue = 180
      #expect(rational.den == 1080)
      numerator.wrappedValue = nil
      #expect(!rational.hasNum && rational.den == 1080)
    }

    @Test("LUB-1048: Classifier Inspector receives the resolved input size")
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
        modelURL: .constant(nil))
      #expect(inspector.inputSize?.width == 1280)
      #expect(inspector.inputSize?.height == 720)
      let value: Ldtx_Workspace_V4_Rational32 = .with { $0.set(num: 1, den: 7) }
      let fields = RationalFractionInput.fields(for: value, defaultDenominator: 1920)
      #expect(fields.numerator == "1")
      #expect(fields.denominator == "7")

    }

    @Test("LUB-1048: Nested ROI bindings update the Store directly")
    func immediateROIBindings() throws {
      let store = WorkspaceDocument(definition: .init(), preferences: .init())
      store.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.visions = [
          WorkspaceResourceFactory.makeLdtxSceneDetectorVision(
            id: 2, name: "Scene", componentID: 1)
        ]
      }
      let boundStore = Bindable(wrappedValue: store)
      let binding = try #require(boundStore.ldtxSceneDetectorVision(internalID: 2))
      binding.regionOfInterest.width.num.wrappedValue = 3
      binding.regionOfInterest.width.den.wrappedValue = 4
      #expect(
        store.workspaceDefinition.visions[0].ldtxSceneDetectorVision.regionOfInterest.width
          .double
          == 0.75)
    }

    @Test("LUB-1048: Classifier added through the sheet flow saves and reopens with its settings")
    func addAndSaveClassifier() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let document = WorkspaceDocument()
      defer { document.close() }
      let store = document.stateService
      store.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents = [
          WorkspaceResourceFactory.makeVFXSource(id: 1, name: "Source")
        ]
      }
      store.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents[0].vfxSource.deviceWidth = 1920
      }
      store.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.videoComponents[0].vfxSource.deviceHeight = 1080
      }
      var draft = WorkspaceAddDraft()
      draft.name = "Scene"
      draft.visionKind = .createMlImageClassifier
      draft.videoComponentID = 1
      let id = try WorkspaceResourceAddition.add(
        sheet: .vision, draft: draft, devices: [], stateService: store)
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
      let reopened = try await loadWorkspaceDocument(at: url)
      defer { reopened.close() }
      #expect(
        reopened.stateService.workspaceDefinition.visions == store.workspaceDefinition.visions)
      #expect(binding.wrappedValue.videoComponentInternalID == 1)
      #expect(binding.wrappedValue.triggers.first?.intervalTrigger.intervalSeconds.double == 5)
    }

    @Test(
      "LUB-1048: Invalid classifier ROI is rejected; bindings do not overwrite a different Vision")
    func rejectInvalidRegionAndRemovedBinding() throws {
      let store = WorkspaceDocument(definition: .init(), preferences: .init())
      store.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.visions = [
          WorkspaceResourceFactory.makeLdtxSceneDetectorVision(
            id: 2, name: "Scene", componentID: 1)
        ]
      }
      let boundStore = Bindable(wrappedValue: store)
      let binding = try #require(boundStore.ldtxSceneDetectorVision(internalID: 2))
      let invalidRegion: Ldtx_Workspace_V4_VisionRegionOfInterest = .with {
        $0.x.set(num: 8, den: 10)
        $0.y.set(num: 0, den: 10)
        $0.width.set(num: 5, den: 10)
        $0.height.set(num: 10, den: 10)
      }
      #expect(throws: (any Error).self) {
        try WorkspaceBundleValidatorV4.validateRegionOfInterest(invalidRegion)
      }
      store.editWorkspace(undoManager: nil) { workspace in
        workspace.definition.visions = [
          WorkspaceResourceFactory.makeOcrVision(id: 2, name: "OCR", componentID: 1)
        ]
      }
      binding.wrappedValue.displayName = "Removed classifier"
      #expect(store.workspaceDefinition.visions.first?.ocrVision.displayName == "OCR")
      #expect(boundStore.ldtxSceneDetectorVision(internalID: 2) == nil)
    }
  }
}
