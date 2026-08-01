// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import LDTXAppCore
import LDTXTaskQueue
import LDTXVision
import LDTXWorkspace
import XCTest

@testable import LDTXFullAppFeatures

@MainActor
final class FeatureProviderTests: XCTestCase {
  func testFullProviderEnablesVision() {
    XCTAssertTrue(FullAppFeatureProvider().configuration.uiFeatures.contains(.vision))
  }

  func testClosedHistogramGateIsSuccessfulSkipForVLMAndOCR() async {
    let feature = WorkspaceVisionFeature(
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
      recordingPackageDirectory: { nil },
      recordingTimelineMilliseconds: { nil },
      presentRecordingFailure: { _ in XCTFail("A skip must not report recording failure") },
      appendLog: { _ in }
    )

    for definition in definitions {
      var result: Result<Void, Error>?
      let completed = expectation(description: "Histogram gate completed for \(definition.name)")
      feature.perform(
        definition,
        stopToken: .neverStopped,
        context: context,
        completion: {
          result = $0
          completed.fulfill()
        }
      )
      await fulfillment(of: [completed], timeout: 5)
      XCTAssertNoThrow(try result?.get())
      XCTAssertNotNil(result)
      XCTAssertNil(feature.presenter.result(forVisionID: definition.id))
    }
  }

  func testHistogramRegionBelowEightPixelsIsClampedForVLMAndOCR() async {
    let feature = WorkspaceVisionFeature(
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
      recordingPackageDirectory: { nil },
      recordingTimelineMilliseconds: { nil },
      presentRecordingFailure: { _ in XCTFail("A closed gate must not archive a frame") },
      appendLog: { _ in }
    )

    for definition in definitions {
      var result: Result<Void, Error>?
      let completed = expectation(description: "Small histogram gate completed for \(definition.name)")
      feature.perform(
        definition,
        stopToken: .neverStopped,
        context: context,
        completion: {
          result = $0
          completed.fulfill()
        }
      )
      await fulfillment(of: [completed], timeout: 5)
      XCTAssertNoThrow(try result?.get())
      XCTAssertNotNil(result)
      XCTAssertNil(feature.presenter.result(forVisionID: definition.id))
    }
  }

  func testClosedHistogramGateClearsRecoveredFrameAcquisitionFailure() async {
    let feature = WorkspaceVisionFeature(
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
      recordingPackageDirectory: { nil },
      recordingTimelineMilliseconds: { nil },
      presentRecordingFailure: { _ in XCTFail("A closed gate must not archive a frame") },
      appendLog: { _ in }
    )

    let firstCompleted = expectation(description: "Frame acquisition failed")
    feature.perform(vision, stopToken: .neverStopped, context: context) { result in
      if case .success = result { XCTFail("Expected frame acquisition failure") }
      firstCompleted.fulfill()
    }
    await fulfillment(of: [firstCompleted], timeout: 5)
    guard case .failed = feature.presenter.status(forVisionID: vision.id) else {
      XCTFail("Expected acquisition failure status")
      return
    }

    let secondCompleted = expectation(description: "Closed gate recovered")
    feature.perform(vision, stopToken: .neverStopped, context: context) { result in
      if case .failure(let error) = result { XCTFail("Unexpected failure: \(error)") }
      secondCompleted.fulfill()
    }
    await fulfillment(of: [secondCompleted], timeout: 5)
    XCTAssertEqual(feature.presenter.status(forVisionID: vision.id), .ready)
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
