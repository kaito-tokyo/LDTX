// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import CoreML
import CoreVideo
import Foundation
import LDTXCapture
import LDTXInternalProtocols
import LDTXProgramRuntime
import LDTXProtos
import LDTXTaskQueue
import LDTXVision
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
import Metal
import Testing
import Vision

@Suite(.serialized)
@MainActor
struct WorkspaceVideoComponentVisionIntegrationTestSuite {
  @Test func generatedComponentAndROIWorkWithoutAProgram() async throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let registry = LowFrequencyUpdateRegistry()
    defer { registry.shutdown() }
    let runtime = makeRuntime(capture: capture)
    runtime.installComponentFrameRenderer(
      VideoComponentFrameRenderer(
        captureSessionCoordinator: capture, lowFrequencyUpdateRegistry: registry))
    defer { runtime.shutdown() }
    let pattern = try runtime.addTestPattern(displayName: "Pattern")
    let id = try runtime.addOcrVision(displayName: "OCR", videoComponentInternalID: pattern)
    var vision = try #require(runtime.visionFeatureContext.vision(id))
    let full = try await runtime.visionFeatureContext.frameForVision(vision)
    #expect(full.image.extent == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    vision.regionOfInterest = .with {
      $0.xRational = .with {
        $0.numerator = 1
        $0.denominator = 4
      }
      $0.yRational = .with {
        $0.numerator = 1
        $0.denominator = 2
      }
      $0.widthRational = .with {
        $0.numerator = 1
        $0.denominator = 2
      }
      $0.heightRational = .with {
        $0.numerator = 1
        $0.denominator = 4
      }
    }
    let cropped = try await runtime.visionFeatureContext.frameForVision(vision)
    #expect(cropped.image.extent == CGRect(x: 480, y: 540, width: 960, height: 270))
    #expect(runtime.definition.programs.isEmpty)
  }

  @Test func clockUsesItsOwnLandscapePixelSize() async throws {
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
    let frame = try await readyFrame(runtime: runtime, vision: vision)
    #expect(frame.image.extent == CGRect(x: 0, y: 0, width: 320, height: 80))
    #expect(runtime.definition.programs.isEmpty)
    // Revision 3's macOS 27 detector requires ANE even with CPU stage assignments.
    // Exercise real Clock OCR with revision 2 on hosted CI, which has no ANE backend.
    let cpu = try #require(
      MLComputeDevice.allComputeDevices.first {
        if case .cpu = $0 { return true }
        return false
      })
    let service = VisionOCRService(
      computeDevice: cpu, requestRevision: VNRecognizeTextRequestRevision2)
    var recognizedClock = false
    for _ in 0..<10 {
      try await Task.sleep(for: .milliseconds(100))
      let current = try await readyFrame(runtime: runtime, vision: vision)
      let output = try await service.recognizeText(
        in: current.image,
        configuration: .init(
          prefersAccurateRecognition: false,
          recognitionLanguages: ["en-US"], usesLanguageCorrection: false), stopToken: .neverStopped)
      #expect(output.elapsedSeconds >= 0)
      recognizedClock = recognizedClock || output.output.contains(":")
    }
    #expect(recognizedClock)
  }

  @Test func sharedCameraUsesIndependentEffectsForOCR() async throws {
    let service = ManualCameraCaptureService()
    let capture = WorkspaceCaptureSessionCoordinator(captureServiceFactory: { service })
    let registry = LowFrequencyUpdateRegistry()
    defer { registry.shutdown() }
    let runtime = makeRuntime(
      capture: capture,
      assignments: [
        1: .avCaptureDevice(uniqueID: "camera"), 2: .avCaptureDevice(uniqueID: "camera"),
      ])
    runtime.installComponentFrameRenderer(
      VideoComponentFrameRenderer(
        captureSessionCoordinator: capture,
        backgroundRemovalPreprocessorFactory: { device, _ in ZeroAlphaPreprocessor(device: device)
        },
        lowFrequencyUpdateRegistry: registry))
    defer { runtime.shutdown() }
    try runtime.editDefinition { definition in
      definition.videoComponents = [UInt64(1), 2].map { id in
        .with { wrapper in
          wrapper.vfxSource = .with { source in
            source.internalID = id
            source.displayName = "Camera \(id)"
            if id == 2 {
              source.effects = [
                .with { $0.backgroundRemoval = .with { $0.model = .mediapipeLandscape } }
              ]
            }
          }
        }
      }
    }
    let failures: Set<String> = await withCheckedContinuation { continuation in
      runtime.synchronizeCaptureInputs(availableCameraIDs: ["camera"]) {
        continuation.resume(returning: $0)
      }
    }
    #expect(failures.isEmpty)
    #expect(service.startCount == 1)
    _ = try #require(try service.emitVideo(frameIndex: 1))
    let rawID = try runtime.addOcrVision(displayName: "Raw OCR", videoComponentInternalID: 1)
    let effectID = try runtime.addOcrVision(displayName: "Effect OCR", videoComponentInternalID: 2)
    let context = runtime.visionFeatureContext
    let raw = try await readyFrame(runtime: runtime, vision: try #require(context.vision(rawID)))
    let effect = try await readyFrame(
      runtime: runtime, vision: try #require(context.vision(effectID)))
    #expect(raw.image.extent == effect.image.extent)
    #expect(raw.image.extent == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    // A zero-alpha effect produces black; the unprocessed synthetic pattern remains visible.
    #expect(try maximumLuma(raw.image) > 80)
    #expect(try maximumLuma(effect.image) < 5)
    #expect(service.startCount == 1)
    await withCheckedContinuation { continuation in capture.stopAndReset { continuation.resume() } }
  }

  @Test func unassignedSourceReportsFailure() async throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let runtime = makeRuntime(capture: capture)
    let source = try runtime.addVFXSource(displayName: "Camera")
    let id = try runtime.addOcrVision(displayName: "OCR", videoComponentInternalID: source)
    let context = runtime.visionFeatureContext
    let vision = try #require(context.vision(id))
    await #expect(throws: WorkspaceVisionFeatureError.vfxSourceHasNoPhysicalCamera) {
      try await context.frameForVision(vision)
    }
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

  private func maximumLuma(_ image: CIImage) throws -> UInt8 {
    let context = CIContext()
    let filter = try #require(CIFilter(name: "CIAreaMaximum"))
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(CIVector(cgRect: image.extent), forKey: kCIInputExtentKey)
    let output = try #require(filter.outputImage)
    var pixel = [UInt8](repeating: 0, count: 4)
    context.render(
      output, toBitmap: &pixel, rowBytes: 4,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
      colorSpace: CGColorSpaceCreateDeviceRGB())
    return pixel.prefix(3).max() ?? 0
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

private final class ZeroAlphaPreprocessor: BackgroundRemovalPreprocessing {
  private let device: any MTLDevice
  init(device: any MTLDevice) { self.device = device }
  func process(pixelBuffer: CVPixelBuffer, sequenceNumber: UInt64)
    -> BackgroundRemovalPreprocessingResult
  {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else { return .unavailable }
    let bytes = [UInt8](repeating: 0, count: width * height)
    bytes.withUnsafeBytes {
      texture.replace(
        region: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width)
    }
    return .ready(alphaTexture: texture)
  }
}
