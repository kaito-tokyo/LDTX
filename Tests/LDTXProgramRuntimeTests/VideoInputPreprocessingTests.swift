// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreVideo
import LDTXInternalProtocols
import Metal
import XCTest

@testable import LDTXProgramRuntime

final class VideoInputPreprocessingTests: XCTestCase {
  func testPassthroughKeepsCapturedPixelBufferUnmodified() throws {
    let pixelBuffer = try makePixelBuffer()
    let frame = CapturedVideoFrame(
      pixelBuffer: pixelBuffer,
      sourcePresentationTime: CMTime(value: 7, timescale: 60),
      captureSessionID: UUID(),
      sequenceNumber: 42
    )

    let result = PassthroughVideoInputPreprocessor().process(frame)

    guard case .ready(let prepared) = result else {
      return XCTFail("Passthrough must make the captured frame ready")
    }
    XCTAssertTrue(prepared.frame.pixelBuffer === pixelBuffer)
    XCTAssertEqual(prepared.frame.sourcePresentationTime, frame.sourcePresentationTime)
    XCTAssertEqual(prepared.frame.sequenceNumber, frame.sequenceNumber)
    XCTAssertNil(prepared.alphaTexture)
    XCTAssertNil(prepared.alphaMaskKind)
  }

  func testPipelineRebuildsAllBlocksWhenSpecificationChanges() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    var textureCache: CVMetalTextureCache?
    XCTAssertEqual(
      CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache),
      kCVReturnSuccess
    )
    let pipeline = VideoInputPreprocessingPipeline(
      device: device,
      textureCache: try XCTUnwrap(textureCache)
    )
    let firstSessionID = UUID()
    let initial = [
      "input": VideoInputPipelineSpecification(
        cameraID: "camera",
        captureSessionID: firstSessionID,
        mode: .passthrough
      )
    ]

    XCTAssertTrue(pipeline.synchronize(specifications: initial))
    XCTAssertFalse(pipeline.synchronize(specifications: initial))

    let restarted = [
      "input": VideoInputPipelineSpecification(
        cameraID: "camera",
        captureSessionID: UUID(),
        mode: .passthrough
      )
    ]
    XCTAssertTrue(pipeline.synchronize(specifications: restarted))

    let reconfigured = [
      "input": VideoInputPipelineSpecification(
        cameraID: "camera",
        captureSessionID: restarted["input"]?.captureSessionID,
        mode: .backgroundRemoval
      )
    ]
    XCTAssertTrue(pipeline.synchronize(specifications: reconfigured))
  }

  func testPipelineUsesInjectedBackgroundRemovalImplementation() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    var textureCache: CVMetalTextureCache?
    XCTAssertEqual(
      CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache),
      kCVReturnSuccess
    )
    var factoryCallCount = 0
    let pipeline = VideoInputPreprocessingPipeline(
      device: device,
      textureCache: try XCTUnwrap(textureCache),
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

    XCTAssertTrue(pipeline.synchronize(specifications: specification))
    XCTAssertEqual(factoryCallCount, 1)

    let frame = CapturedVideoFrame(
      pixelBuffer: try makePixelBuffer(),
      sourcePresentationTime: CMTime(value: 7, timescale: 60),
      captureSessionID: UUID(),
      sequenceNumber: 42
    )
    guard case .unavailable = pipeline.process(frame, forInputKey: "input") else {
      return XCTFail("The injected background-removal implementation must handle the frame")
    }
  }

  func testBackgroundRemovalReceivesTheOriginalCapturedFrame() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    var textureCache: CVMetalTextureCache?
    XCTAssertEqual(
      CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache),
      kCVReturnSuccess
    )
    let spy = BackgroundRemovalSpy()
    let pipeline = VideoInputPreprocessingPipeline(
      device: device,
      textureCache: try XCTUnwrap(textureCache),
      backgroundRemovalPreprocessorFactory: { _, _ in spy }
    )
    let captureSessionID = UUID()
    XCTAssertTrue(pipeline.synchronize(specifications: [
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

    XCTAssertTrue(spy.pixelBuffer === pixelBuffer)
    XCTAssertEqual(spy.sequenceNumber, 42)
  }

  private func makePixelBuffer() throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        16,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
        &pixelBuffer
      ),
      kCVReturnSuccess
    )
    return try XCTUnwrap(pixelBuffer)
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
