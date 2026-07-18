// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreVideo
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
