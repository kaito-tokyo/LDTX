// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import CoreImage
import Foundation
import LDTXTaskQueue
import LDTXWorkspace
@preconcurrency import Vision

public actor VisionOCRService {
  public init() {}

  public func recognizeText(
    in image: CIImage,
    definition: WorkspaceVisionOCRDefinition,
    stopToken: StopToken
  ) async throws -> VisionAnalysis {
    try stopToken.check()
    try Task.checkCancellation()
    let startedAt = ContinuousClock.now
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = definition.recognitionLevel == .fast ? .fast : .accurate
    if !definition.recognitionLanguages.isEmpty {
      request.recognitionLanguages = definition.recognitionLanguages
    } else {
      request.automaticallyDetectsLanguage = true
    }
    request.usesLanguageCorrection = definition.usesLanguageCorrection

    let operation = VisionOCRRequestOperation(image: image, request: request)
    try await withTaskCancellationHandler {
      try await Task.detached { [operation] in
        try stopToken.check()
        try operation.perform()
        try stopToken.check()
      }.value
    } onCancel: {
      operation.cancel()
    }
    try stopToken.check()
    let output = (request.results ?? [])
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
    let elapsed = ContinuousClock.now - startedAt
    return VisionAnalysis(
      output: output,
      elapsedSeconds: Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1e18
    )
  }
}

private final class VisionOCRRequestOperation: @unchecked Sendable {
  private let handler: VNImageRequestHandler
  private let request: VNRecognizeTextRequest

  init(image: CIImage, request: VNRecognizeTextRequest) {
    handler = VNImageRequestHandler(ciImage: image)
    self.request = request
  }

  func perform() throws {
    try handler.perform([request])
  }

  func cancel() {
    request.cancel()
  }
}
