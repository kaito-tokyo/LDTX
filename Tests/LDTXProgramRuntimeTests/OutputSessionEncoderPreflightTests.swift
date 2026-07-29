// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXMP4
import Metal
import XCTest

@testable import LDTXProgramRuntime

final class OutputSessionEncoderPreflightTests: XCTestCase {
  func testPreflightEncodesMetalTestPatternWithOutputContract() async throws {
    try XCTSkipUnless(MTLCreateSystemDefaultDevice() != nil, "Metal is unavailable")
    let previewFrames = PreflightPreviewFrameCollector()
    let encodedOutput = OutputSessionEncoderPreflightOutput()
    let configuration = SegmentedMP4WriterConfiguration(
      width: 1_920,
      height: 1_080,
      frameRate: 60,
      videoBitRate: 6_000_000,
      audioSampleRate: 48_000,
      audioChannelCount: 2,
      audioBitRate: 128_000,
      segmentDurationSeconds: 2
    )
    let encoder = try H264VideoEncoder(
      configuration: H264VideoEncoderConfiguration(
        width: 1_920,
        height: 1_080,
        frameRate: 60,
        bitRate: 6_000_000,
        keyFrameIntervalSeconds: 2,
        requiresHardwareAcceleration: true
      ),
      outputHandler: { encodedOutput.append($0) }
    )
    let runtime = ProgramRuntime(
      captureSessionCoordinator: WorkspaceCaptureSessionCoordinator(),
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(interval: .seconds(60))
    )
    runtime.updateProgram(OutputSessionPreflightProgram.configuration(for: configuration))
    let encoderHandlerID = runtime.addFrameHandler(replayLatestFrame: false) { frame in
      encoder.encode(
        pixelBuffer: frame.pixelBuffer,
        presentationTime: frame.presentationTime ?? .zero,
        duration: .invalid
      )
    }
    runtime.beginOutput()
    defer {
      runtime.removeFrameHandler(id: encoderHandlerID)
      runtime.endOutput()
      encoder.finish { _ in }
    }

    try await OutputSessionEncoderPreflight.run(
      configuration: configuration,
      runtime: runtime,
      encodedOutput: encodedOutput,
      previewFrameHandler: { previewFrames.append($0) }
    )
    XCTAssertEqual(previewFrames.frameIDs.count, 90)
    XCTAssertEqual(previewFrames.frameIDs, Array(1...90))
  }
}

private final class PreflightPreviewFrameCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storedFrameIDs: [UInt64] = []

  var frameIDs: [UInt64] { lock.withLock { storedFrameIDs } }

  func append(_ frame: OutputSessionPreflightPreviewFrame) {
    lock.withLock { storedFrameIDs.append(frame.frameID) }
  }
}
