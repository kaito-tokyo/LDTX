// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXCapture
import LDTXInternalProtocols
import LDTXProgramRuntime
import LDTXProtos
import LDTXVision
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
import Testing

@Suite(.serialized)
@MainActor
struct WorkspaceVideoComponentVisionIntegrationTestSuite {
  @Test
  func clockOutputIsRecognized() async throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let registry = LowFrequencyUpdateRegistry()
    defer { registry.shutdown() }
    let runtime = makeRuntime(capture: capture)
    runtime.installComponentFrameRenderer(
      VideoComponentFrameRenderer(
        captureSessionCoordinator: capture, lowFrequencyUpdateRegistry: registry))
    defer { runtime.shutdown() }
    let clock = try runtime.addClock(displayName: "Clock")
    let id = try runtime.addOcrVision(displayName: "OCR", videoComponentInternalID: clock)
    let vision = try #require(runtime.visionFeatureContext.vision(id))
    let service = VisionOCRService()
    var recognizedClock = false
    for _ in 0..<10 {
      try await Task.sleep(for: .milliseconds(100))
      let current = try await readyFrame(runtime: runtime, vision: vision)
      let output = try await service.recognizeText(
        in: current.image,
        configuration: .init(
          recognitionLanguages: [], usesLanguageCorrection: false))
      #expect(output.elapsedSeconds >= 0)
      recognizedClock = recognizedClock || output.output.contains(":")
    }
    #expect(recognizedClock)
  }

  private func readyFrame(runtime: WorkspaceWindowRuntime, vision: Ldtx_Workspace_V4_OcrVision)
    async throws -> WorkspaceVisionAnalysisFrame
  {
    for _ in 0..<100 {
      do {
        return try await runtime.visionFeatureContext.frameForVision(vision)
      } catch WorkspaceVisionFeatureError.frameUnavailable {
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    throw WorkspaceVisionFeatureError.frameUnavailable
  }

  private func makeRuntime(
    capture: WorkspaceCaptureSessionCoordinator,
    assignments: [UInt64: WorkspacePhysicalDeviceID] = [:]
  ) -> WorkspaceWindowRuntime {
    let box = WorkspaceBox()
    let persistence = WorkspaceV4PersistenceCoordinator(
      workspaceSnapshot: { box.workspace },
      replaceWorkspace: {
        try WorkspaceV4IntegrityValidator.validate($0)
        box.workspace = $0
      }, url: nil)
    return WorkspaceWindowRuntime(
      persistence: persistence, captureSessionCoordinator: capture,
      physicalDeviceIDs: { assignments })
  }

  private final class WorkspaceBox {
    var workspace = WorkspaceV4Bundle(definition: .init(), preferences: .init())
  }
}
