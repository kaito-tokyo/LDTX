// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace
import Testing

@testable import LDTXVision

@MainActor
@Suite
struct VisionRuntimeStoreUnitTestSuite {
  @Test("maps legacy Workspace OCR settings into format-independent settings")
  func mapsWorkspaceOCRConfiguration() {
    let configuration = VisionOCRConfiguration(definition: .init(
      recognitionLevel: .fast,
      recognitionLanguages: ["ja-JP"],
      usesLanguageCorrection: false
    ))

    #expect(!configuration.prefersAccurateRecognition)
    #expect(configuration.recognitionLanguages == ["ja-JP"])
    #expect(!configuration.usesLanguageCorrection)
    #expect(configuration.customWords.isEmpty)
    #expect(configuration.minimumTextHeight == nil)
  }

  @Test("Changing OCR configuration invalidates runtime state")
  func definitionChangeInvalidatesRuntimeState() {
    let store = VisionRuntimeStore()
    var vision = WorkspaceVisionDefinition(name: "OCR")
    store.synchronize(visions: [vision])
    store.accept(VisionAnalysis(output: "old", elapsedSeconds: 1), for: vision)

    vision.definition.recognitionLevel = .fast
    store.synchronize(visions: [vision])

    #expect(store.status(for: vision) == .ready)
    #expect(store.resultsByVisionID[vision.id] == nil)
    #expect(store.analysesByVisionID[vision.id] == nil)
  }

  @Test("Editing a histogram gate preserves runtime state")
  func histogramGateChangePreservesRuntimeState() {
    let store = VisionRuntimeStore()
    var vision = WorkspaceVisionDefinition(name: "OCR")
    store.synchronize(visions: [vision])
    store.accept(VisionAnalysis(output: "result", elapsedSeconds: 1), for: vision)

    vision.histogramGate = .init(
      channel: .hue, binCount: 15, expectedPeakBin: 8, minimumPeakRatio: 0.5)
    store.synchronize(visions: [vision])

    #expect(store.status(for: vision) == .ready)
    #expect(store.resultsByVisionID[vision.id] == "result")
  }

  @Test("Only acquisition failures are cleared after frame recovery")
  func acquisitionFailureRecoveryIsScoped() {
    let store = VisionRuntimeStore()
    let vision = WorkspaceVisionDefinition(name: "OCR")
    store.synchronize(visions: [vision])

    store.reportAcquisitionFailure(for: vision.id, message: "No frame")
    store.clearAcquisitionFailure(for: vision)
    #expect(store.status(for: vision) == .ready)

    store.reportFailure(for: vision.id, message: "OCR failed")
    store.clearAcquisitionFailure(for: vision)
    #expect(store.status(for: vision) == .failed(message: "OCR failed"))
  }
}
