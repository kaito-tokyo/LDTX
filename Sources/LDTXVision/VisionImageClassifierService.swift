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
  public nonisolated let modelInformation: ModelInformation

  public struct ModelInformation: Equatable, Sendable {
    public let cropAndScaleAction: ImageCropAndScaleAction
    public let description: String?
    public let author: String?
    public let inputWidth: Int?
    public let inputHeight: Int?

    public init(
      creatorDefined: [String: String], description: String? = nil, author: String? = nil,
      inputWidth: Int? = nil, inputHeight: Int? = nil
    ) {
      switch creatorDefined["tokyo.kaito.LDTX.cropAndScale"] {
      case "scaleFit": cropAndScaleAction = .scaleToFit
      case "scaleFill": cropAndScaleAction = .scaleToFill
      case "scaleFitRotate90CCW": cropAndScaleAction = .scaleToFitPlus90CCWRotation
      case "scaleFillRotate90CCW": cropAndScaleAction = .scaleToFillPlus90CCWRotation
      default: cropAndScaleAction = .centerCrop
      }
      self.description = description
      self.author = author
      self.inputWidth = inputWidth
      self.inputHeight = inputHeight
    }

    fileprivate init(model: MLModel) {
      let description = model.modelDescription
      let input = description.inputDescriptionsByName.sorted(by: { $0.key < $1.key })
        .compactMap { $0.value.imageConstraint }.first
      self.init(
        creatorDefined: description.metadata[.creatorDefinedKey] as? [String: String] ?? [:],
        description: description.metadata[.description] as? String,
        author: description.metadata[.author] as? String,
        inputWidth: input?.pixelsWide, inputHeight: input?.pixelsHigh)
    }
  }

  public init(model: sending MLModel) throws {
    self.modelInformation = ModelInformation(model: model)
    self.modelContainer = try CoreMLModelContainer(model: model)
  }

  public func classify(image: CIImage) async throws -> String {
    var request = CoreMLRequest(model: modelContainer)
    request.cropAndScaleAction = modelInformation.cropAndScaleAction
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

  @concurrent public static func loadModel(
    at url: URL,
    configuration: MLModelConfiguration = .init(),
    noCompile: Bool = false,
    cachesDirectory: URL = URL.cachesDirectory.appending(
      path: "tokyo.kaito.LDTX", directoryHint: .isDirectory),
    fileManager: FileManager = .default
  ) async throws -> MLModel {
    let digest = try modelDigest(at: url, fileManager: fileManager)
    let hexString = digest.map { String(format: "%02x", $0) }.joined()
    let targetURL = cachesDirectory.appending(
      path: "\(hexString).mlmodelc", directoryHint: .isDirectory)

    if !noCompile, !fileManager.fileExists(atPath: targetURL.path(percentEncoded: false)) {
      let compiledURL = try await MLModel.compileModel(at: url)
      try fileManager.createDirectory(
        at: cachesDirectory, withIntermediateDirectories: true)
      do {
        try fileManager.moveItem(at: compiledURL, to: targetURL)
      } catch {
        try? fileManager.removeItem(at: compiledURL)
        guard fileManager.fileExists(atPath: targetURL.path(percentEncoded: false)) else { throw error }
      }
    }

    return try MLModel(contentsOf: targetURL, configuration: configuration)
  }

  @concurrent public static func readModelInformation(
    at url: URL, noCompile: Bool = false
  ) async throws -> ModelInformation {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let model = try await loadModel(at: url, noCompile: noCompile)
    return ModelInformation(model: model)
  }

  private static func modelDigest(at url: URL, fileManager: FileManager) throws -> SHA384.Digest {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    if attributes[.type] as? FileAttributeType == .typeRegular {
      return SHA384.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }
    guard url.pathExtension.lowercased() == "mlpackage",
      attributes[.type] as? FileAttributeType == .typeDirectory
    else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url]) }
    var files: [(path: String, url: URL)] = []
    func visit(_ directory: URL, prefix: String) throws {
      for child in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        let path = prefix + child.lastPathComponent
        let attributes = try fileManager.attributesOfItem(atPath: child.path)
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory: try visit(child, prefix: path + "/")
        case .typeRegular: files.append((path, child))
        default: throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: child])
        }
      }
    }
    try visit(url, prefix: "")
    var hash = SHA384()
    for file in files.sorted(by: { $0.path < $1.path }) {
      hash.update(data: Data(file.path.utf8))
      hash.update(data: Data([0]))
      let digest = SHA384.hash(data: try Data(contentsOf: file.url, options: .mappedIfSafe))
      hash.update(data: Data(digest))
    }
    return hash.finalize()
  }
}
