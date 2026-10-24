// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import CoreML
import CreateMLComponents
import Foundation
import LDTXProtos
import LDTXRichText
import LDTXVision
import LDTXVisionTraining
import LDTXWorkspaceAppletModel
@testable import LDTXWorkspaceAppletService
import Synchronization
import Testing
import Vision

@Suite("Scene Detector", .tags(.hard), .serialized)
struct SceneDetectorIntegrationTestSuite {
  @Test("LUB-1023: Preparation rejects feature extractor model")
  func preparationRejectsFeatureExtractorModel() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("Features.mlpackage")
    try ImageFeaturePrint(revision: 2).export(to: url)
    let compiled = try await MLModel.compileModel(at: url)
    defer { try? FileManager.default.removeItem(at: compiled) }
    #expect(throws: (any Error).self) {
      try VisionImageClassifierService(model: MLModel(contentsOf: compiled))
    }
  }

  @Test(
    "LUB-1045: Archives only frames acquired during the same recording",
    arguments: [
      (nil, "new", false), ("old", nil, false), ("old", "new", false),
      ("same", "same", true),
    ] as [(String?, String?, Bool)])
  @MainActor
  func archiveUsesFrameRecordingURL(initial: String?, final: String?, shouldArchive: Bool)
    async throws
  {
    var recordingURL = initial.map { URL(fileURLWithPath: "/\($0).ldtxrecord") }
    var continuation: CheckedContinuation<String, Never>?
    let feature = WorkspaceV4VisionFeature(
      scheduler: WorkspaceVisionScheduler(automaticTimer: false),
      recognizeText: { _, _ in
        await withCheckedContinuation { continuation = $0 }
      })
    let vision = Ldtx_Workspace_V4_OcrVision.with { $0.internalID = 1 }
    var result: String?
    var archives = 0
    var context = WorkspaceV4VisionFeatureContext(
      vision: { _ in vision },
      frameForVision: { _ in WorkspaceVisionAnalysisFrame(image: CIImage.empty()) },
      reportResult: { _, output in result = output },
      reportFailure: { _, error in Issue.record(error) },
      archiveResult: { _, _, _ in archives += 1 })
    context.recordingPackageURL = { recordingURL }
    feature.submit(visionInternalID: 1, context: context)
    try await waitUntil { continuation != nil }
    recordingURL = final.map { URL(fileURLWithPath: "/\($0).ldtxrecord") }
    continuation?.resume(returning: "Result")
    try await waitUntil { result != nil }
    await feature.stop()
    #expect(archives == (shouldArchive ? 1 : 0))
  }

  @Test("LUB-1023: Crop and scale uses creator defined metadata")
  func cropAndScaleUsesCreatorDefinedMetadata() {
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
    #expect(
      VisionImageClassifierService.ModelInformation(creatorDefined: [:]).cropAndScaleAction
        == .centerCrop)
  }

  @Test("LUB-1024: Reads class folders and exports model") func readsClassFoldersAndExportsModel()
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
    let trainer = try await LDTXSceneDetectorTrainer.prepare(
      at: directory, maxIterations: 10, cropAndScale: .scaleFit)
    #expect(trainer.files.count == 60)
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
    await #expect(throws: (any Error).self) {
      _ = try await VisionImageClassifierService.readModelInformation(
        at: savedURL, cachesDirectory: caches)
    }
    #expect(!FileManager.default.fileExists(atPath: caches.path))
    let loaded = try await VisionImageClassifierService.loadModel(
      at: savedURL, cachesDirectory: caches)
    let information = try await VisionImageClassifierService.readModelInformation(
      at: savedURL, cachesDirectory: caches)
    #expect(loaded.modelDescription.predictedFeatureName != nil)
    let metadata = loaded.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
    let service = try VisionImageClassifierService(model: loaded)
    #expect(information.cropAndScaleAction == service.modelInformation.cropAndScaleAction)
    #expect(
      service.modelInformation.cropAndScaleAction
        == VisionImageClassifierService.ModelInformation(creatorDefined: metadata)
        .cropAndScaleAction)
    #expect(service.modelInformation.inputWidth == 360)
    #expect(service.modelInformation.inputHeight == 360)
    _ = try await VisionImageClassifierService.loadModel(
      at: savedURL, noCompile: true, cachesDirectory: caches)
    let copied = directory.appendingPathComponent("Copied.mlpackage", isDirectory: true)
    try FileManager.default.copyItem(at: savedURL, to: copied)
    _ = try await VisionImageClassifierService.loadModel(
      at: copied, noCompile: true, cachesDirectory: caches)
    try Data([1]).write(to: copied.appendingPathComponent("content-change.bin"))
    await #expect(throws: (any Error).self) {
      _ = try await VisionImageClassifierService.loadModel(
        at: copied, noCompile: true, cachesDirectory: caches)
    }
    let cachedModel = try #require(
      try FileManager.default.contentsOfDirectory(
        at: caches, includingPropertiesForKeys: nil
      ).first { $0.pathExtension == "mlmodelc" })
    let corruptCaches = directory.appendingPathComponent("CorruptCaches", isDirectory: true)
    try FileManager.default.createDirectory(at: corruptCaches, withIntermediateDirectories: true)
    let corruptModel = corruptCaches.appendingPathComponent(cachedModel.lastPathComponent)
    try Data([1, 2, 3]).write(to: corruptModel)
    await #expect(throws: (any Error).self) {
      _ = try await VisionImageClassifierService.loadModel(
        at: savedURL, cachesDirectory: corruptCaches)
    }
    #expect(try Data(contentsOf: corruptModel) == Data([1, 2, 3]))
    let standalone = directory.appendingPathComponent("FeaturePrint.mlmodel")
    try ImageFeaturePrint(revision: 2, cropAndScale: .scaleFit).export(to: standalone)
    _ = try await VisionImageClassifierService.loadModel(at: standalone, cachesDirectory: caches)
    try await verifyAutomaticRequests(
      modelURL: savedURL, caches: caches, imageURL: directory.appendingPathComponent("red/0.png"))
  }

  @MainActor
  private func verifyAutomaticRequests(modelURL: URL, caches: URL, imageURL: URL) async throws {
    let image = try #require(CIImage(contentsOf: imageURL))
    var time = 0.0
    let scheduler = WorkspaceVisionScheduler(
      now: { time }, random: { _ in 0 }, automaticTimer: false)
    var loads = 0
    var prepared = false
    let feature = WorkspaceV4VisionFeature(
      scheduler: scheduler,
      recognizeText: { frame, configuration in
        // Test scheduler coexistence independently of TextRecognition's unavailable CI backends.
        #expect(frame.extent == image.extent)
        #expect(configuration.recognitionLanguages == ["en-US"])
        return "Scheduled OCR"
      },
      loadClassifier: { url, noCompile in
        loads += 1
        let model = try await VisionImageClassifierService.loadModel(
          at: url, noCompile: noCompile, cachesDirectory: caches)
        let service = try VisionImageClassifierService(model: model)
        prepared = true
        return service
      })
    let trigger = Ldtx_Workspace_V4_VisionTriggerWrapper.with {
      $0.intervalTrigger.intervalSeconds.set(num: 1, den: 1)
    }
    var classifier = Ldtx_Workspace_V4_LdtxSceneDetectorVision.with {
      $0.internalID = 5
      $0.modelInternalID = 7
      $0.triggers = [trigger]
    }
    let ocr = Ldtx_Workspace_V4_OcrVision.with {
      $0.internalID = 3
      $0.triggers = [trigger]
      $0.recognitionLanguages = ["en-US"]
    }
    func wrappers() -> [Ldtx_Workspace_V4_VisionWrapper] {
      [.with { $0.ldtxSceneDetectorVision = classifier }, .with { $0.ocrVision = ocr }]
    }
    var results: [(Int64, String)] = []
    var variables: [Int64: [LDTXVariableItem: String]] = [:]
    var preparedModelIDs: [Int64] = []
    var failures: [Error] = []
    var archived: [Int64] = []
    var holdFrame = false
    var frameContinuation: CheckedContinuation<Void, Never>?
    var context = WorkspaceV4VisionFeatureContext(
      vision: { $0 == 3 ? ocr : nil },
      frameForVision: { _ in WorkspaceVisionAnalysisFrame(image: image) },
      reportResult: { results.append(($0, $1)) },
      reportFailure: { _, error in failures.append(error) },
      archiveResult: { id, _, _ in archived.append(id) })
    context.sceneDetector = { $0 == 5 ? classifier : nil }
    context.reportVariables = { variables[$0] = $1 }
    context.recordingPackageURL = { URL(fileURLWithPath: "/test.ldtxrecord") }
    context.reportModelPrepared = { preparedModelIDs.append($0) }
    context.modelURL = { $0 == 7 ? modelURL : nil }
    context.frameForSceneDetector = { _ in
      if holdFrame { await withCheckedContinuation { frameContinuation = $0 } }
      return WorkspaceVisionAnalysisFrame(image: image)
    }
    feature.synchronize(visions: wrappers(), context: context)
    try await waitUntil { prepared }
    await feature.prepareForOutput()
    #expect(preparedModelIDs == [7])
    let loadedService = await feature.classifierService(modelID: 7, url: modelURL)
    context.isOutputActive = { true }
    feature.synchronize(visions: wrappers(), context: context)
    let outputService = await feature.classifierService(modelID: 7, url: modelURL)
    #expect(loadedService === outputService)
    #expect(loads == 1)
    scheduler.tick()
    try await waitUntil { results.count == 1 || !failures.isEmpty }
    #expect(results.first?.0 == 5)
    #expect(results.first?.1.contains("red") == true)
    #expect(variables[5]?[.label] == "red")
    let confidence = try #require(variables[5]?[.confidence].flatMap(Float.init))
    #expect((0...1).contains(confidence))
    time = 3
    for _ in 0..<10 { await Task.yield() }
    scheduler.tick()
    try await waitUntil { results.count == 2 || !failures.isEmpty }
    #expect(results.last?.0 == 3)
    #expect(results.last?.1 == "Scheduled OCR")
    #expect(variables[3] == [.text: "Scheduled OCR"])
    #expect(archived == [5, 3])
    #expect(loads == 1)
    #expect(failures.isEmpty)
    #expect(preparedModelIDs == [7])
    time = 1000
    holdFrame = true
    for _ in 0..<10 { await Task.yield() }
    scheduler.tick()
    try await waitUntil { frameContinuation != nil }
    context.videoComponents = [.with { $0.vfxSource.deviceWidth = 1280 }]
    feature.synchronize(visions: wrappers(), context: context)
    frameContinuation?.resume()
    await feature.stop()
    #expect(results.count == 2)
    #expect(loads == 1)

    var active = true
    var attempts: [Bool] = []
    var preparationErrors = 0
    let missingCache = caches.appendingPathComponent("Missing")
    let cold = WorkspaceV4VisionFeature(
      scheduler: WorkspaceVisionScheduler(automaticTimer: false),
      loadClassifier: { url, noCompile in
        attempts.append(noCompile)
        let model = try await VisionImageClassifierService.loadModel(
          at: url, noCompile: noCompile, cachesDirectory: missingCache)
        return try VisionImageClassifierService(model: model)
      })
    context.isOutputActive = { active }
    context.reportFailure = { _, _ in preparationErrors += 1 }
    cold.synchronize(visions: wrappers(), context: context)
    await cold.prepareForOutput()
    #expect(await cold.classifierService(modelID: 7, url: modelURL) == nil)
    cold.synchronize(visions: wrappers(), context: context)
    try await Task.sleep(for: .milliseconds(20))
    #expect(attempts.isEmpty)
    #expect(preparationErrors == 0)
    #expect(!FileManager.default.fileExists(atPath: missingCache.path))
    active = false
    cold.outputStateDidChange()
    await cold.prepareForOutput()
    #expect(await cold.classifierService(modelID: 7, url: modelURL) != nil)
    active = true
    cold.outputStateDidChange()
    #expect(await cold.classifierService(modelID: 7, url: modelURL) != nil)
    await cold.stop()
    #expect(attempts == [false])

    active = false
    var failedLoads = 0
    var recoveries: [Int64] = []
    context.reportPreparationRecovered = { recoveries.append($0) }
    let failed = WorkspaceV4VisionFeature(
      scheduler: WorkspaceVisionScheduler(automaticTimer: false),
      loadClassifier: { _, noCompile in
        #expect(!noCompile)
        failedLoads += 1
        if failedLoads == 1 { throw CocoaError(.fileReadCorruptFile) }
        return try VisionImageClassifierService(
          model: await VisionImageClassifierService.loadModel(
            at: modelURL, cachesDirectory: caches))
      })
    failed.synchronize(visions: wrappers(), context: context)
    await failed.prepareForOutput()
    let attemptsBeforeOutput = failedLoads
    active = true
    failed.outputStateDidChange()
    #expect(await failed.classifierService(modelID: 7, url: modelURL) == nil)
    #expect(failedLoads == attemptsBeforeOutput)
    active = false
    failed.outputStateDidChange()
    await failed.prepareForOutput()
    #expect(failedLoads == attemptsBeforeOutput + 1)
    #expect(recoveries == [5])
    await failed.stop()
  }

  @MainActor
  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !predicate(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(predicate())
  }
}
