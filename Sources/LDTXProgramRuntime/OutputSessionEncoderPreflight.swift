// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreVideo
import Foundation
import LDTXMP4
import LDTXProgram

enum OutputSessionEncoderPreflightError: Error, LocalizedError {
  case missingEncodedFrame
  case timedOut(frameCount: Int)

  var errorDescription: String? {
    switch self {
    case .missingEncodedFrame:
      "The output encoder preflight produced no compressed video frame."
    case let .timedOut(frameCount):
      "The output encoder preflight timed out after receiving \(frameCount) frames."
    }
  }
}

public struct OutputSessionPreflightPreviewFrame: @unchecked Sendable {
  public let frameID: UInt64
  public let pixelBuffer: CVPixelBuffer

  public init(frameID: UInt64, pixelBuffer: CVPixelBuffer) {
    self.frameID = frameID
    self.pixelBuffer = pixelBuffer
  }
}

/// The isolated Program used to exercise the same Program Runtime rendering
/// path as an active Workspace Program without consuming any Workspace input.
enum OutputSessionPreflightProgram {
  static func configuration(
    for output: SegmentedMP4WriterConfiguration
  ) -> ProgramRuntimeConfiguration {
    ProgramRuntimeConfiguration(
      composite: CompositeProgramDefinition(steps: [
        CompositeProgramStep(id: "output-preflight-test-pattern", component: .testPattern)
      ]),
      audioChannels: [],
      canvasWidth: output.width,
      canvasHeight: output.height,
      outputWidth: output.width,
      outputHeight: output.height,
      frameRate: output.frameRate,
      timeSeconds: 0,
      videoPTSMasterCameraID: nil,
      cameraIDsByInputKey: [:],
      cameraInputColorOverrides: [:],
      backgroundRemovalInputKeys: []
    )
  }
}

/// Verifies the active Program Runtime-to-VideoToolbox path before an Output
/// Session starts consuming capture, audio, or external output resources.
enum OutputSessionEncoderPreflight {
  private static let warmupDurationMilliseconds = 1_500
  private static let timeoutSeconds = 10

  static func run(
    configuration: SegmentedMP4WriterConfiguration,
    runtime: ProgramRuntime,
    encodedOutput: OutputSessionEncoderPreflightOutput,
    previewFrameHandler: @escaping @Sendable (OutputSessionPreflightPreviewFrame) -> Void
  ) async throws {
    let frameCount = configuration.frameRate * warmupDurationMilliseconds / 1_000
    let receivedFrames = OutputSessionPreflightFrameGate(targetFrameCount: frameCount)
    let frameHandlerID = runtime.addFrameHandler(replayLatestFrame: false) { frame in
      guard receivedFrames.accept(frame) else { return }
      previewFrameHandler(OutputSessionPreflightPreviewFrame(
        frameID: frame.frameID,
        pixelBuffer: frame.pixelBuffer))
    }
    defer {
      runtime.removeFrameHandler(id: frameHandlerID)
    }
    try await receivedFrames.wait(timeout: .seconds(timeoutSeconds))
    try await encodedOutput.validate(timeout: .seconds(timeoutSeconds))
  }
}

private final class OutputSessionPreflightFrameGate: @unchecked Sendable {
  private let targetFrameCount: Int
  private let lock = NSLock()
  private var receivedFrameCount = 0
  private var completion: CheckedContinuation<Void, Never>?

  init(targetFrameCount: Int) {
    self.targetFrameCount = targetFrameCount
  }

  func accept(_ frame: ProgramFrame) -> Bool {
    guard !frame.isPreparingRenderResources else { return false }
    let completed: CheckedContinuation<Void, Never>? = lock.withLock {
      guard receivedFrameCount < targetFrameCount else { return nil }
      receivedFrameCount += 1
      guard receivedFrameCount == targetFrameCount else { return nil }
      defer { self.completion = nil }
      return self.completion
    }
    completed?.resume()
    return true
  }

  func wait(timeout: Duration) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        await waitForCompletion()
      }
      group.addTask { [self] in
        try await Task.sleep(for: timeout)
        throw OutputSessionEncoderPreflightError.timedOut(frameCount: frameCount)
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }

  private var frameCount: Int { lock.withLock { receivedFrameCount } }

  private func waitForCompletion() async {
    let isComplete = lock.withLock { receivedFrameCount >= targetFrameCount }
    guard !isComplete else { return }
    await withCheckedContinuation { continuation in
      let completed = lock.withLock { () -> Bool in
        if receivedFrameCount >= targetFrameCount { return true }
        completion = continuation
        return false
      }
      if completed { continuation.resume() }
    }
  }
}

final class OutputSessionEncoderPreflightOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<CMSampleBuffer, any Error>?
  private var completion: CheckedContinuation<Void, Never>?

  func validate(timeout: Duration) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        await waitForResult()
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw OutputSessionEncoderPreflightError.missingEncodedFrame
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
    try lock.withLock {
      guard let result else { throw OutputSessionEncoderPreflightError.missingEncodedFrame }
      _ = try result.get()
    }
  }

  func append(_ result: Result<CMSampleBuffer, any Error>) {
    let completion: CheckedContinuation<Void, Never>? = lock.withLock {
      guard self.result == nil else { return nil }
      self.result = result
      defer { self.completion = nil }
      return self.completion
    }
    completion?.resume()
  }

  private func waitForResult() async {
    guard lock.withLock({ result == nil }) else { return }
    await withCheckedContinuation { continuation in
      let alreadyReceived = lock.withLock { () -> Bool in
        if result != nil { return true }
        completion = continuation
        return false
      }
      if alreadyReceived { continuation.resume() }
    }
  }
}
