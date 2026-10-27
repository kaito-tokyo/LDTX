// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import CoreVideo
import Foundation
import LDTXCapture
import LDTXCorelibs
import LDTXInternalProtocols
import LDTXProgramRuntime
import LDTXVision
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
import Testing

@Suite(.tags(.hard), .serialized)
@MainActor
struct WorkspaceClockOCRIntegrationTestSuite {
  @Test("LUB-1023: Clock output is recognized")
  func clockOutputIsRecognized() async throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let runtime = makeRuntime(capture: capture)
    let landscape = ProgramRuntime(captureSessionCoordinator: capture)
    let portrait = ProgramRuntime(captureSessionCoordinator: capture)
    runtime.installRuntimes(landscape: landscape, portrait: portrait)
    defer {
      landscape.stopPreview()
      runtime.shutdown()
    }
    let program = try runtime.addProgram(displayName: "Clock OCR")
    let clock = try runtime.addClock(displayName: "Clock")
    try runtime.setVideoLayerOrder([clock], forProgramInternalID: program, target: .landscape)
    landscape.startPreview()

    var current: ProgramFrame?
    for _ in 0..<100 {
      if let frame = landscape.latestFrame(), !frame.isPreparingRenderResources {
        current = frame
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let frame = try #require(current)
    let output = try await VisionOCRService().recognizeText(
      in: CIImage(cvPixelBuffer: frame.pixelBuffer),
      configuration: .init(
        recognitionLanguages: ["en-US"], usesLanguageCorrection: false))
    #expect(output.elapsedSeconds >= 0)
    #expect(output.output.contains(":"), "OCR output: \(output.output)")
  }

  private func makeRuntime(
    capture: WorkspaceCaptureSessionCoordinator,
    assignments: [Int64: WorkspacePhysicalDeviceID] = [:]
  ) -> WorkspaceWindowRuntime {
    let box = WorkspaceBox()
    let persistence = WorkspaceV4PersistenceCoordinator(
      workspaceSnapshot: { box.workspace },
      replaceWorkspace: {
        try WorkspaceBundleValidatorV4.validate($0)
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
