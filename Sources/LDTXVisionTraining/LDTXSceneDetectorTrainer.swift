// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CreateMLComponents
import Foundation
import Vision

public struct LDTXSceneDetectorTrainer {
  public let files: AnnotatedFiles

  public let maxIterations: Int
  public let cropAndScale: VNImageCropAndScaleOption
  public let metadata: ModelMetadata

  private let labels: Set<String>
  private let featureExtractor: ImageFeaturePrint
  private let classifier: LogisticRegressionClassifier<Float, String>

  @concurrent
  public static func prepare(
    at datasetURL: URL, maxIterations: Int = 25,
    cropAndScale: VNImageCropAndScaleOption = .centerCrop
  ) async throws -> sending Self {
    let files = try AnnotatedFiles(labeledBySubdirectoryNamesAt: datasetURL, type: .image)
    return Self(files: files, maxIterations: maxIterations, cropAndScale: cropAndScale)
  }

  public init(
    files: AnnotatedFiles,
    maxIterations: Int = 25,
    cropAndScale: VNImageCropAndScaleOption = .centerCrop,
    metadata: ModelMetadata = .init(description: "Scene Detector created by LDTX using Create ML")
  ) {
    self.files = files
    self.maxIterations = maxIterations
    self.cropAndScale = cropAndScale
    self.metadata = metadata
    self.labels = Set(files.map(\.annotation))
    self.featureExtractor = .init(revision: 2, cropAndScale: cropAndScale)
    self.classifier = .init(labels: labels, configuration: .init(maxIterations: maxIterations))
  }

  @concurrent
  public func fit(to url: URL, eventHandler: EventHandler? = nil) async throws -> URL {
    let features = try await ImageReader().appending(featureExtractor)
      .applied(to: files, eventHandler: eventHandler)
    let (train, val) = features.randomSplit(by: 0.95)
    let fittedClassifier = try await classifier.fitted(
      to: train, validateOn: val, eventHandler: eventHandler)

    var metadata = self.metadata
    metadata.creatorDefined["tokyo.kaito.LDTX.maxIterations"] = String(maxIterations)
    metadata.creatorDefined["tokyo.kaito.LDTX.cropAndScale"] = cropAndScale.string

    try featureExtractor.appending(fittedClassifier).export(to: url, metadata: metadata)

    return url
  }
}

extension LogisticRegressionClassifier.Configuration {
  fileprivate init(maxIterations: Int) {
    self.init()
    self.maximumIterations = maxIterations
  }
}

extension VNImageCropAndScaleOption {
  fileprivate var string: String {
    switch self {
    case .centerCrop: "centerCrop"
    case .scaleFill: "scaleFill"
    case .scaleFillRotate90CCW: "scaleFillRotate90CCW"
    case .scaleFit: "scaleFit"
    case .scaleFitRotate90CCW: "scaleFitRotate90CCW"
    @unknown default: ""
    }
  }
}
