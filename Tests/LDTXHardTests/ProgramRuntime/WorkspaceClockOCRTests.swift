// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXVision
import Testing

@Suite(.serialized)
@MainActor
struct WorkspaceClockOCRIntegrationTestSuite {
  @Test func clockOutputIsRecognized() async throws {
    // Exercise the current independent Clock producer and Program compositor.
    // A Clock is no longer a valid persisted Workspace Vision input.
    let capture = WorkspaceCaptureSessionCoordinator()
    let renderer = VideoComponentFrameRenderer(captureSessionCoordinator: capture)
    let producer = ProgramOverlayProducer()
    defer {
      producer.stop()
      renderer.stopAndDrain {}
    }
    let configuration = ProgramRuntimeConfiguration(
      composite: .init(steps: [.init(id: "clock", component: .clock(.init(fontSize: 64)))]),
      audioChannels: [], canvasWidth: 900, canvasHeight: 200,
      outputWidth: 900, outputHeight: 200, frameRate: 30, timeSeconds: 0,
      videoPTSMasterCameraID: nil, cameraIDsByInputKey: [:],
      cameraInputColorOverrides: [:], backgroundRemovalInputKeys: [],
      overlayTextures: producer.textures)
    producer.update(configuration: configuration)
    for _ in 0..<100 where producer.textures.snapshot()["clock"] == nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(producer.textures.snapshot()["clock"] != nil)
    let service = VisionOCRService()
    var recognizedClock = false
    for _ in 0..<10 {
      try await Task.sleep(for: .milliseconds(100))
      let frame = try await renderer.render(componentID: 1, configuration: configuration)
      #expect(!frame.isPreparingRenderResources)
      let output = try await service.recognizeText(
        in: CIImage(cvPixelBuffer: frame.pixelBuffer),
        configuration: .init(recognitionLanguages: [], usesLanguageCorrection: false))
      #expect(output.elapsedSeconds >= 0)
      recognizedClock = recognizedClock || output.output.contains(":")
    }
    #expect(recognizedClock)
  }
}
