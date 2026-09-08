// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import LDTXAppCore
import LDTXTaskQueue
import LDTXVision
import LDTXWorkspace
import Testing

@testable import LDTXFullAppFeatures

@MainActor
@Suite
struct FeatureProviderEasyTests {
  @Test func closedHistogramGateIsSuccessfulSkipForVLMAndOCR() async {
    let feature = FullWorkspaceVisionFeature(
      workspaceResourceQueue: WorkspaceResourceQueue(label: "test.histogram-gate")
    )
    var definitions = [WorkspaceVisionDefinition]()
    var vlm = WorkspaceVisionDefinition(name: "VLM")
    vlm.histogramGate = closedBlackGate
    definitions.append(vlm)
    var ocr = WorkspaceVisionDefinition(name: "OCR")
    ocr.definition = .opticalCharacterRecognition(.init())
    ocr.histogramGate = closedBlackGate
    definitions.append(ocr)
    var releasedRecordingLeaseCount = 0
    let context = WorkspaceVisionFeatureContext(
      isSessionRunning: { true },
      visionNamed: { id in definitions.first { $0.id == id } },
      frameForVision: { _ in
        WorkspaceVisionAnalysisFrame(
          image: CIImage(color: .white).cropped(
            to: CGRect(x: 0, y: 0, width: 64, height: 36)
          )
        )
      },
      beginRecordingOperation: {
        WorkspaceVisionRecordingLease(
          packageDirectory: URL(fileURLWithPath: "/tmp/test.ldtxrecord"),
          timelineMilliseconds: 0,
          releaseHandler: { releasedRecordingLeaseCount += 1 })
      },
      presentRecordingFailure: { _ in Issue.record("A skip must not report recording failure") },
      appendLog: { _ in }
    )

    for definition in definitions {
      let result = await perform(feature, definition: definition, context: context)
      switch result {
      case .success: break
      case .failure(let error): Issue.record("Unexpected failure: \(error)")
      }
      #expect(feature.presenter.result(forVisionID: definition.id) == nil)
    }
    #expect(releasedRecordingLeaseCount == definitions.count)
  }

  @Test func histogramRegionBelowEightPixelsIsClampedForVLMAndOCR() async {
    let feature = FullWorkspaceVisionFeature(
      workspaceResourceQueue: WorkspaceResourceQueue(label: "test.histogram-gate-size")
    )
    var definitions = [WorkspaceVisionDefinition]()
    var vlm = WorkspaceVisionDefinition(name: "VLM")
    vlm.histogramGate = undersizedGate
    definitions.append(vlm)
    var ocr = WorkspaceVisionDefinition(name: "OCR")
    ocr.definition = .opticalCharacterRecognition(.init())
    ocr.histogramGate = undersizedGate
    definitions.append(ocr)
    let context = WorkspaceVisionFeatureContext(
      isSessionRunning: { true },
      visionNamed: { id in definitions.first { $0.id == id } },
      frameForVision: { _ in
        WorkspaceVisionAnalysisFrame(
          image: CIImage(color: .white).cropped(
            to: CGRect(x: 0, y: 0, width: 64, height: 36)
          )
        )
      },
      beginRecordingOperation: { nil },
      presentRecordingFailure: { _ in Issue.record("A closed gate must not archive a frame") },
      appendLog: { _ in }
    )

    for definition in definitions {
      let result = await perform(feature, definition: definition, context: context)
      switch result {
      case .success: break
      case .failure(let error): Issue.record("Unexpected failure: \(error)")
      }
      #expect(feature.presenter.result(forVisionID: definition.id) == nil)
    }
  }

  @Test func closedHistogramGateClearsRecoveredFrameAcquisitionFailure() async {
    let feature = FullWorkspaceVisionFeature(
      workspaceResourceQueue: WorkspaceResourceQueue(label: "test.histogram-gate-recovery")
    )
    var vision = WorkspaceVisionDefinition(name: "OCR")
    vision.definition = .opticalCharacterRecognition(.init())
    vision.histogramGate = closedBlackGate
    var frameAttempts = 0
    let context = WorkspaceVisionFeatureContext(
      isSessionRunning: { true },
      visionNamed: { id in id == vision.id ? vision : nil },
      frameForVision: { _ in
        frameAttempts += 1
        if frameAttempts == 1 { throw TestError.noFrame }
        return WorkspaceVisionAnalysisFrame(
          image: CIImage(color: .white).cropped(
            to: CGRect(x: 0, y: 0, width: 64, height: 36)
          )
        )
      },
      beginRecordingOperation: { nil },
      presentRecordingFailure: { _ in Issue.record("A closed gate must not archive a frame") },
      appendLog: { _ in }
    )

    let firstResult = await perform(feature, definition: vision, context: context)
    if case .success = firstResult { Issue.record("Expected frame acquisition failure") }
    guard case .failed = feature.presenter.status(forVisionID: vision.id) else {
      Issue.record("Expected acquisition failure status")
      return
    }

    let secondResult = await perform(feature, definition: vision, context: context)
    if case .failure(let error) = secondResult { Issue.record("Unexpected failure: \(error)") }
    #expect(feature.presenter.status(forVisionID: vision.id) == .ready)
  }

  private func perform(
    _ feature: FullWorkspaceVisionFeature,
    definition: WorkspaceVisionDefinition,
    context: WorkspaceVisionFeatureContext
  ) async -> Result<Void, Error> {
    await withCheckedContinuation { continuation in
      feature.perform(definition, stopToken: .neverStopped, context: context) {
        continuation.resume(returning: $0)
      }
    }
  }

  private var closedBlackGate: WorkspaceVisionHistogramGate {
    .init(channel: .value, binCount: 8, expectedPeakBin: 0, minimumPeakRatio: 0.8)
  }

  private var undersizedGate: WorkspaceVisionHistogramGate {
    .init(region: .init(x: 0, y: 0, width: 0.01, height: 0.01))
  }

  private enum TestError: Error {
    case noFrame
  }
}
