// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import CoreML
import CreateMLComponents
import Foundation
import LDTXVisionTraining
import Synchronization
import Testing
import Vision

@Suite("Scene Detector", .serialized)
struct SceneDetectorIntegrationTestSuite {
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
    var trainer = LDTXSceneDetectorTrainer(files: files)
    trainer.maxIterations = 10
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
  }
}
