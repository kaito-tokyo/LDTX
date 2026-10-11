// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import CoreImage
import CoreML
import Foundation
import Vision

/// Serializes model loading and image classification off the main actor.
public actor VisionImageClassifierService {
  public init() {}

  public func classify(image: CIImage, modelURL: URL) async throws -> String {
    let compiledURL = try await MLModel.compileModel(at: modelURL)
    defer { try? FileManager.default.removeItem(at: compiledURL) }
    try Task.checkCancellation()
    let model = try MLModel(contentsOf: compiledURL)
    let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
    request.imageCropAndScaleOption = .centerCrop
    try VNImageRequestHandler(ciImage: image).perform([request])
    try Task.checkCancellation()
    guard let results = request.results as? [VNClassificationObservation] else {
      throw CocoaError(
        .coderInvalidValue,
        userInfo: [NSLocalizedDescriptionKey: "The model did not return image classifications."])
    }
    return results.map {
      "\($0.identifier): \(String(format: "%.1f%%", $0.confidence * 100))"
    }.joined(separator: "\n")
  }
}
