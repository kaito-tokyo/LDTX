// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import CoreImage
import CoreML
import CryptoKit
import Foundation
import Vision

/// Performs image classification off the main actor.
public actor VisionImageClassifierService {
  private let modelContainer: CoreMLModelContainer

  public init(model: sending MLModel) throws {
    self.modelContainer = try CoreMLModelContainer(model: model)
  }

  public func classify(image: CIImage) async throws -> String {
    var request = CoreMLRequest(model: modelContainer)
    request.cropAndScaleAction = .scaleToFit
    let observations = try await request.perform(on: image)
    guard let results = observations as? [ClassificationObservation] else {
      throw CocoaError(
        .coderInvalidValue,
        userInfo: [NSLocalizedDescriptionKey: "The model did not return image classifications."])
    }
    return results.map {
      "\($0.identifier): \(String(format: "%.1f%%", $0.confidence * 100))"
    }.joined(separator: "\n")
  }

  public static func loadModel(
    at url: URL,
    configuration: MLModelConfiguration = .init(),
    noCompile: Bool = false,
    cachesDirectory: URL = URL.cachesDirectory.appending(
      path: "tokyo.kaito.LDTX", directoryHint: .isDirectory),
    fileManager: FileManager = .default
  ) async throws -> MLModel {
    let digest = SHA384.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
    let hexString = digest.map { String(format: "%02x", $0) }.joined()
    let targetURL = cachesDirectory.appending(
      path: "\(hexString).mlmodelc", directoryHint: .isDirectory)

    if !noCompile, !fileManager.fileExists(atPath: targetURL.path(percentEncoded: false)) {
      let compiledURL = try await MLModel.compileModel(at: url)
      try fileManager.createDirectory(
        at: cachesDirectory, withIntermediateDirectories: true)
      try fileManager.moveItem(at: compiledURL, to: targetURL)
    }

    return try MLModel(contentsOf: targetURL, configuration: configuration)
  }
}
