// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import CoreML
import CreateMLComponents
import Foundation
import LDTXVisionTraining
import LDTXVision
import Synchronization
import Testing
import Vision

@Suite("Scene Detector", .serialized)
struct SceneDetectorIntegrationTestSuite {
  @Test func cropAndScaleUsesCreatorDefinedMetadata() {
    let cases: [(String, ImageCropAndScaleAction)] = [
      ("centerCrop", .centerCrop), ("scaleFit", .scaleToFit), ("scaleFill", .scaleToFill),
      ("scaleFitRotate90CCW", .scaleToFitPlus90CCWRotation),
      ("scaleFillRotate90CCW", .scaleToFillPlus90CCWRotation),
      ("", .centerCrop), ("unknown", .centerCrop),
    ]
    for (value, expected) in cases {
      let information = VisionImageClassifierService.ModelInformation(
        creatorDefined: ["tokyo.kaito.LDTX.cropAndScale": value])
      #expect(information.cropAndScaleAction == expected)
    }
    #expect(VisionImageClassifierService.ModelInformation(creatorDefined: [:]).cropAndScaleAction == .centerCrop)
  }

  @Test func readsClassFoldersAndExportsModel()
    async throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = CIContext()
    for (label, color) in [("red", CIColor.red), ("blue", CIColor.blue)] {
      let folder = directory.appendingPathComponent(label)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for index in 0..<30 {
        let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 360, height: 360))
        try context.writePNGRepresentation(
          of: image, to: folder.appendingPathComponent("\(index).png"),
          format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
      }
    }
    let files = try AnnotatedFiles(labeledBySubdirectoryNamesAt: directory, type: .image)
    let trainer = LDTXSceneDetectorTrainer(files: files, maxIterations: 10, cropAndScale: .scaleFit)
    let events = Mutex<[Event]>([])
    let savedURL = directory.appendingPathComponent("SceneDetector.mlpackage", isDirectory: true)
    let exportedURL = try await trainer.fit(to: savedURL) { event in
      events.withLock { $0.append(event) }
    }
    #expect(exportedURL == savedURL)
    #expect(events.withLock { !$0.isEmpty })
    let compiledURL = try await MLModel.compileModel(at: savedURL)
    defer { try? FileManager.default.removeItem(at: compiledURL) }
    let request = CoreMLRequest(
      model: try CoreMLModelContainer(model: MLModel(contentsOf: compiledURL)))
    let observations = try await request.perform(
      on: CIImage(contentsOf: directory.appendingPathComponent("red/0.png"))!)
    let classifications = observations.compactMap { $0 as? ClassificationObservation }
    #expect(classifications.first?.identifier == "red")
    let caches = directory.appendingPathComponent("Caches", isDirectory: true)
    let loaded = try await VisionImageClassifierService.loadModel(at: savedURL, cachesDirectory: caches)
    #expect(loaded.modelDescription.predictedFeatureName != nil)
    let metadata = loaded.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
    let service = try VisionImageClassifierService(model: loaded)
    #expect(service.modelInformation.cropAndScaleAction
      == VisionImageClassifierService.ModelInformation(creatorDefined: metadata).cropAndScaleAction)
    #expect(service.modelInformation.inputWidth == 360)
    #expect(service.modelInformation.inputHeight == 360)
    _ = try await VisionImageClassifierService.loadModel(
      at: savedURL, noCompile: true, cachesDirectory: caches)
    let copied = directory.appendingPathComponent("Copied.mlpackage", isDirectory: true)
    try FileManager.default.copyItem(at: savedURL, to: copied)
    _ = try await VisionImageClassifierService.loadModel(at: copied, noCompile: true, cachesDirectory: caches)
    try Data([1]).write(to: copied.appendingPathComponent("content-change.bin"))
    await #expect(throws: (any Error).self) {
      _ = try await VisionImageClassifierService.loadModel(at: copied, noCompile: true, cachesDirectory: caches)
    }
    let standalone = directory.appendingPathComponent("FeaturePrint.mlmodel")
    try ImageFeaturePrint(revision: 2, cropAndScale: .scaleFit).export(to: standalone)
    _ = try await VisionImageClassifierService.loadModel(at: standalone, cachesDirectory: caches)
  }
}
