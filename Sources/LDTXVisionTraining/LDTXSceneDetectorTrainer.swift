// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CreateMLComponents
import Foundation
import Vision

public struct LDTXSceneDetectorTrainer: Sendable {
  let files: AnnotatedFiles

  public var maxIterations: Int = 25
  var cropAndScale: VNImageCropAndScaleOption = .scaleFit
  var metadata = ModelMetadata(description: "Scene Detector created by LDTX using Create ML")

  private let labels: Set<String>

  public init(files: AnnotatedFiles) {
    self.files = files
    self.labels = Set(files.map(\.annotation))
  }

  @concurrent
  public func fit(to url: URL, eventHandler: EventHandler? = nil) async throws -> URL {
    let estimator = ImageFeaturePrint(revision: 2, cropAndScale: cropAndScale)
      .appending(
        LogisticRegressionClassifier<Float, String>(
          labels: labels, configuration: .init(maxIterations: maxIterations)))

    let images = try files.mapFeatures(ImageReader.read(url:))
    let (train, val) = images.randomSplit(by: 0.95)
    let model = try await estimator.fitted(to: train, validateOn: val, eventHandler: eventHandler)

    var metadata = self.metadata
    metadata.creatorDefined["tokyo.kaito.LDTX.maxIterations"] = String(maxIterations)
    metadata.creatorDefined["tokyo.kaito.LDTX.cropAndScale"] = cropAndScale.string

    try model.export(to: url, metadata: metadata)

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
