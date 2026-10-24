// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXProtos
import LDTXRichText
import LDTXWorkspaceAppletModel
@testable import LDTXWorkspaceAppletService
import Testing

@MainActor
@Suite(.tags(.medium), .timeLimit(.minutes(1)))
struct WorkspaceVisionVariableIntegrationTestSuite {
  @Test(
    "LUB-1071: Manual and automatic OCR publish variables", arguments: [false, true],
    ["recognized", "", "failure"])
  func manualAndAutomaticOCRPublishVariables(automatic: Bool, output: String) async throws {
    let vision = Ldtx_Workspace_V4_OcrVision.with {
      $0.internalID = 11
      $0.triggers = [.with { $0.intervalTrigger.intervalSeconds.set(num: 1, den: 1) }]
    }
    let definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4.with {
      $0.visions = [.with { $0.ocrVision = vision }]
    }
    let key = LDTXVariableKey(visionID: 11, item: .text)
    var store = [LDTXVariableKey: String](definition: definition)
    try store.update([key: "previous"])
    let scheduler = WorkspaceVisionScheduler(now: { 0 }, random: { _ in 0 }, automaticTimer: false)
    let feature = WorkspaceV4VisionFeature(
      scheduler: scheduler,
      recognizeText: { _, _ in
        if output == "failure" { throw CocoaError(.fileReadUnknown) }
        return output
      })
    var display = ""
    var failure = false
    await withCheckedContinuation { (completion: CheckedContinuation<Void, Never>) in
      var context = WorkspaceV4VisionFeatureContext(
        vision: { $0 == 11 ? vision : nil },
        frameForVision: { _ in .init(image: CIImage(color: .white)) },
        reportResult: { _, result in display = result },
        reportFailure: { id, _ in
          failure = true
          store.reset(visionID: id)
          completion.resume()
        })
      context.reportVariables = { id, values in
        do {
          try store.update(
            Dictionary(
              uniqueKeysWithValues: values.map {
                (LDTXVariableKey(visionID: id, item: $0.key), $0.value)
              }))
        } catch { Issue.record("Unexpected variable update: \(error)") }
        completion.resume()
      }
      feature.synchronize(visions: definition.visions, context: context)
      if automatic {
        scheduler.tick()
      } else {
        feature.runOCR(visionInternalID: 11)
      }
    }
    #expect(store[key] == (output == "failure" ? "" : output))
    #expect(failure == (output == "failure"))
    if !failure { #expect(display == output) }
    await feature.stop()
  }
}
