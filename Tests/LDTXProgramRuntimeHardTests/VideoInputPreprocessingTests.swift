// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreVideo
import LDTXInternalProtocols
import Metal
import Testing

@testable import LDTXProgramRuntime

@Suite
struct VideoInputPreprocessingIntegrationTestSuite {
  @Test func passthroughKeepsCapturedPixelBufferUnmodified() throws {
    let pixelBuffer = try makePixelBuffer()
    let frame = CapturedVideoFrame(
      pixelBuffer: pixelBuffer,
      sourcePresentationTime: CMTime(value: 7, timescale: 60),
      captureSessionID: UUID(),
      sequenceNumber: 42
    )

    let result = PassthroughVideoInputPreprocessor().process(frame)

    guard case .ready(let prepared) = result else {
      Issue.record("Passthrough must make the captured frame ready")
      return
    }
    #expect(prepared.frame.pixelBuffer === pixelBuffer)
    #expect(prepared.frame.sourcePresentationTime == frame.sourcePresentationTime)
    #expect(prepared.frame.sequenceNumber == frame.sequenceNumber)
    #expect(prepared.alphaTexture == nil)
    #expect(prepared.alphaMaskKind == nil)
  }

  @Test func pipelineRebuildsAllBlocksWhenSpecificationChanges() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    var textureCache: CVMetalTextureCache?
    let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    #expect(status == kCVReturnSuccess)
    let pipeline = VideoInputPreprocessingPipeline(
      device: device,
      textureCache: try #require(textureCache)
    )
    let firstSessionID = UUID()
    let initial = [
      "input": VideoInputPipelineSpecification(
        cameraID: "camera",
        captureSessionID: firstSessionID,
        mode: .passthrough
      )
    ]

    #expect(pipeline.synchronize(specifications: initial))
    #expect(!pipeline.synchronize(specifications: initial))

    let restarted = [
      "input": VideoInputPipelineSpecification(
        cameraID: "camera",
        captureSessionID: UUID(),
        mode: .passthrough
      )
    ]
    #expect(pipeline.synchronize(specifications: restarted))

    let reconfigured = [
      "input": VideoInputPipelineSpecification(
        cameraID: "camera",
        captureSessionID: restarted["input"]?.captureSessionID,
        mode: .backgroundRemoval
      )
    ]
    #expect(pipeline.synchronize(specifications: reconfigured))
  }

  @Test func pipelineUsesInjectedBackgroundRemovalImplementation() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    var textureCache: CVMetalTextureCache?
    let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    #expect(status == kCVReturnSuccess)
    var factoryCallCount = 0
    let pipeline = VideoInputPreprocessingPipeline(
      device: device,
      textureCache: try #require(textureCache),
      backgroundRemovalPreprocessorFactory: { _, _ in
        factoryCallCount += 1
        return UnavailableBackgroundRemovalPreprocessor()
      }
    )
    let specification = [
      "input": VideoInputPipelineSpecification(
        cameraID: "camera",
        captureSessionID: UUID(),
        mode: .backgroundRemoval
      )
    ]

    #expect(pipeline.synchronize(specifications: specification))
    #expect(factoryCallCount == 1)

    let frame = CapturedVideoFrame(
      pixelBuffer: try makePixelBuffer(),
      sourcePresentationTime: CMTime(value: 7, timescale: 60),
      captureSessionID: UUID(),
      sequenceNumber: 42
    )
    guard case .unavailable = pipeline.process(frame, forInputKey: "input") else {
      Issue.record("The injected background-removal implementation must handle the frame")
      return
    }
  }

  @Test func backgroundRemovalReceivesTheOriginalCapturedFrame() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    var textureCache: CVMetalTextureCache?
    let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    #expect(status == kCVReturnSuccess)
    let spy = BackgroundRemovalSpy()
    let pipeline = VideoInputPreprocessingPipeline(
      device: device,
      textureCache: try #require(textureCache),
      backgroundRemovalPreprocessorFactory: { _, _ in spy }
    )
    let captureSessionID = UUID()
    #expect(
      pipeline.synchronize(specifications: [
        "input": VideoInputPipelineSpecification(
          cameraID: "camera",
          captureSessionID: captureSessionID,
          mode: .backgroundRemoval
        )
      ]))
    let pixelBuffer = try makePixelBuffer()
    let frame = CapturedVideoFrame(
      pixelBuffer: pixelBuffer,
      sourcePresentationTime: CMTime(value: 91, timescale: 60),
      captureSessionID: captureSessionID,
      sequenceNumber: 42
    )

    _ = pipeline.process(frame, forInputKey: "input")

    #expect(spy.pixelBuffer === pixelBuffer)
    #expect(spy.sequenceNumber == 42)
  }

  private func makePixelBuffer() throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      16,
      16,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
      &pixelBuffer)
    #expect(status == kCVReturnSuccess)
    return try #require(pixelBuffer)
  }
}

private final class UnavailableBackgroundRemovalPreprocessor: BackgroundRemovalPreprocessing {
  func process(
    pixelBuffer: CVPixelBuffer,
    sequenceNumber: UInt64
  ) -> BackgroundRemovalPreprocessingResult {
    .unavailable
  }
}

private final class BackgroundRemovalSpy: BackgroundRemovalPreprocessing {
  private(set) var pixelBuffer: CVPixelBuffer?
  private(set) var sequenceNumber: UInt64?

  func process(
    pixelBuffer: CVPixelBuffer,
    sequenceNumber: UInt64
  ) -> BackgroundRemovalPreprocessingResult {
    self.pixelBuffer = pixelBuffer
    self.sequenceNumber = sequenceNumber
    return .unavailable
  }
}
