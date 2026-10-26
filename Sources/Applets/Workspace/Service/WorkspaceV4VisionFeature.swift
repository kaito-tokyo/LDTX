// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXCorelibs
import LDTXRichText
import LDTXVision
import LDTXWorkspaceAppletModel
import OSLog
import Observation

/// Automatic OCR and Scene Detector execution from the persisted Definition.
@MainActor
@Observable
public final class WorkspaceV4VisionFeature: WorkspaceV4VisionFeatureProviding {
  public private(set) var resultsByVisionInternalID: [Int64: String] = [:]
  @ObservationIgnored private let recognizeText:
    (CIImage, VisionOCRConfiguration) async throws -> String
  @ObservationIgnored private let scheduler: WorkspaceVisionScheduler
  @ObservationIgnored private let loadClassifier:
    (URL, Bool) async throws -> VisionImageClassifierService
  @ObservationIgnored private var context: WorkspaceV4VisionFeatureContext?
  @ObservationIgnored private var visions: [Ldtx_Workspace_V4_VisionWrapper] = []
  private var manualTasks: [Int64: Task<Void, Never>] = [:]
  @ObservationIgnored private var models: [ModelKey: VisionImageClassifierService] = [:]
  @ObservationIgnored private var modelKeys: Set<ModelKey> = []
  @ObservationIgnored private var preparations: [ModelKey: Task<Void, Never>] = [:]
  @ObservationIgnored private var modelFailures: [ModelKey: Error] = [:]
  @ObservationIgnored private var preparationGeneration = UUID()
  @ObservationIgnored private var outputActive = false
  @ObservationIgnored private var stopped = false
  private static let logger = Logger(subsystem: "tokyo.kaito.ldtx", category: "VisionScheduler")

  private struct ModelKey: Hashable {
    let id: Int64
    let url: URL
  }

  public convenience init() {
    self.init(scheduler: WorkspaceVisionScheduler())
  }

  init(
    scheduler: WorkspaceVisionScheduler,
    recognizeText: @escaping (CIImage, VisionOCRConfiguration) async throws -> String = {
      image, configuration in
      try await VisionOCRService().recognizeText(in: image, configuration: configuration).output
    },
    loadClassifier: @escaping (URL, Bool) async throws -> VisionImageClassifierService = {
      url, noCompile in
      let model = try await VisionImageClassifierService.loadModel(at: url, noCompile: noCompile)
      return try VisionImageClassifierService(model: model)
    }
  ) {
    self.scheduler = scheduler
    self.recognizeText = recognizeText
    self.loadClassifier = loadClassifier
  }

  public func synchronize(
    visions: [Ldtx_Workspace_V4_VisionWrapper], context: WorkspaceV4VisionFeatureContext
  ) {
    let keys = Set(
      visions.compactMap { wrapper -> ModelKey? in
        guard case .ldtxSceneDetectorVision(let vision)? = wrapper.vision,
          let modelID = vision.modelInternalID, let url = context.modelURL(modelID)
        else { return nil }
        return ModelKey(id: modelID, url: url)
      })
    let changed =
      stopped || self.visions != visions || self.context == nil || keys != modelKeys
      || self.context?.videoComponents != context.videoComponents
    modelKeys = keys
    self.context = context
    self.visions = visions
    stopped = false
    if changed {
      preparationGeneration = UUID()
      modelFailures.removeAll()
      let validIDs = Set(visions.compactMap(\.internalID))
      resultsByVisionInternalID = resultsByVisionInternalID.filter { validIDs.contains($0.key) }
      models = models.filter { keys.contains($0.key) }
      let triggers = visions.flatMap { wrapper -> [WorkspaceVisionSchedule.Trigger] in
        guard let id = wrapper.internalID else { return [] }
        let triggers: [Ldtx_Workspace_V4_VisionTriggerWrapper]
        switch wrapper.vision {
        case .ocrVision(let vision):
          triggers = vision.triggers
        case .ldtxSceneDetectorVision(let vision):
          triggers = vision.triggers
        case nil: return []
        }
        return triggers.compactMap {
          guard case .intervalTrigger(let interval)? = $0.trigger else { return nil }
          return .init(
            visionID: id,
            periodMilliseconds: (interval.intervalSeconds?.double(
              defaultNumerator: 0, defaultDenominator: 1) ?? 0) * 1000)
        }
      }
      _ = scheduler.synchronize(
        triggers: triggers,
        isReady: { [weak self] id in
          guard let self, let context = self.context else { return false }
          if context.vision(id) != nil { return true }
          guard let vision = context.sceneDetector(id),
            let modelID = vision.modelInternalID, let url = context.modelURL(modelID)
          else { return false }
          return models[ModelKey(id: modelID, url: url)] != nil
        },
        execute: { [weak self] id, generation in
          await self?.execute(id, generation: generation)
        })
    }
    outputStateDidChange()
    prepareModels()
  }

  public func outputStateDidChange() {
    guard let context, !stopped else { return }
    let active = context.isOutputActive()
    guard outputActive != active else { return }
    outputActive = active
    preparationGeneration = UUID()
    modelFailures.removeAll()
    prepareModels()
  }

  public func stop() async {
    stopped = true
    preparationGeneration = UUID()
    await scheduler.stop()
    for task in Array(preparations.values) { await task.value }
    for task in Array(manualTasks.values) { await task.value }
    preparations.removeAll()
    models.removeAll()
    context = nil
    Self.logger.info(
      "vision-schedule stopped dropped=\(self.scheduler.dropped) skipped=\(self.scheduler.skipped) overruns=\(self.scheduler.overruns)"
    )
  }

  public func prepareForOutput() async {
    guard let context, !context.isOutputActive(), !stopped else { return }
    modelFailures.removeAll()
    prepareModels()
    while !preparations.isEmpty {
      for task in Array(preparations.values) { await task.value }
    }
  }

  public func classifierService(modelID: Int64, url: URL) async -> VisionImageClassifierService? {
    let key = ModelKey(id: modelID, url: url)
    if let context, !context.isOutputActive(), !stopped {
      prepareModels()
      await preparations[key]?.value
    }
    return stopped ? nil : models[key]
  }

  private func prepareModels() {
    guard let context, !context.isOutputActive(), !stopped else { return }
    for wrapper in visions {
      guard case .ldtxSceneDetectorVision(let vision)? = wrapper.vision,
        let visionID = vision.internalID,
        let modelID = vision.modelInternalID, let url = context.modelURL(modelID)
      else { continue }
      let key = ModelKey(id: modelID, url: url)
      if let error = modelFailures[key] { context.reportFailure(visionID, error) }
      guard models[key] == nil, preparations[key] == nil, modelFailures[key] == nil else {
        continue
      }
      let generation = preparationGeneration
      let noCompile = context.isOutputActive()
      preparations[key] = Task { [weak self] in
        guard let self else { return }
        defer {
          preparations[key] = nil
          if !stopped && generation != preparationGeneration { prepareModels() }
        }
        do {
          let service = try await loadClassifier(url, noCompile)
          guard !stopped, generation == preparationGeneration else { return }
          models[key] = service
          for wrapper in visions {
            guard case .ldtxSceneDetectorVision(let current)? = wrapper.vision,
              let currentID = current.internalID,
              current.modelInternalID == key.id, self.context?.modelURL(key.id) == key.url
            else { continue }
            self.context?.reportPreparationRecovered(currentID)
          }
          self.context?.reportModelPrepared(key.id)
        } catch {
          guard !stopped, generation == preparationGeneration else { return }
          modelFailures[key] = error
          for wrapper in visions {
            guard case .ldtxSceneDetectorVision(let current)? = wrapper.vision,
              let currentID = current.internalID,
              current.modelInternalID == key.id, self.context?.modelURL(key.id) == key.url
            else { continue }
            self.context?.reportFailure(currentID, error)
          }
        }
      }
    }
  }

  public func canRunOCR(visionInternalID: Int64) -> Bool {
    !stopped && manualTasks[visionInternalID] == nil
      && visions.contains { wrapper in
        guard case .ocrVision(let vision)? = wrapper.vision else { return false }
        return vision.internalID == visionInternalID
      }
  }

  public func runOCR(
    visionInternalID: Int64, isCurrent: @escaping () -> Bool = { true }
  ) {
    guard canRunOCR(visionInternalID: visionInternalID), var context else { return }
    let runtimeIsCurrent = context.isCurrent
    context.isCurrent = { runtimeIsCurrent() && isCurrent() }
    submit(visionInternalID: visionInternalID, context: context)
  }

  public func submit(visionInternalID: Int64, context: WorkspaceV4VisionFeatureContext) {
    guard manualTasks[visionInternalID] == nil, !stopped else { return }
    manualTasks[visionInternalID] = Task { [weak self] in
      guard let self else { return }
      defer { manualTasks[visionInternalID] = nil }
      await execute(visionInternalID, generation: nil, explicitContext: context)
    }
  }

  private func execute(
    _ id: Int64, generation: UUID?, explicitContext: WorkspaceV4VisionFeatureContext? = nil
  ) async {
    guard let context = explicitContext ?? context, !stopped else { return }
    let ocr = context.vision(id)
    let classifier = context.sceneDetector(id)
    let url = classifier?.modelInternalID.flatMap { context.modelURL($0) }
    func isCurrent() -> Bool {
      !stopped && context.isCurrent() && (generation.map { scheduler.isCurrent($0) } ?? true)
        && (self.context?.videoComponents ?? context.videoComponents) == context.videoComponents
        && context.vision(id) == ocr && context.sceneDetector(id) == classifier
        && (classifier.map { $0.modelInternalID.flatMap { context.modelURL($0) } == url } ?? true)
    }
    do {
      let frame: WorkspaceVisionAnalysisFrame
      let recordingPackageURL: URL?
      let output: String
      let variables: [LDTXVariableItem: String]
      if let ocr {
        frame = try await context.frameForVision(ocr)
        recordingPackageURL = context.recordingPackageURL()
        output = try await recognizeText(frame.image, Self.ocrConfiguration(for: ocr))
        variables = [.text: output]
      } else if let classifier, let modelID = classifier.modelInternalID, let url,
        let frameProvider = context.frameForSceneDetector
      {
        guard let service = models[ModelKey(id: modelID, url: url)] else {
          return
        }
        frame = try await frameProvider(classifier)
        recordingPackageURL = context.recordingPackageURL()
        let result = try await service.classifyResult(image: frame.image)
        output = result.displayText
        variables = [
          .label: result.topCandidate?.label ?? "",
          .confidence: result.topCandidate.map { String($0.confidence) } ?? "0",
        ]
      } else {
        return
      }
      guard isCurrent() else { return }
      resultsByVisionInternalID[id] = output
      context.reportResult(id, output)
      context.reportVariables(id, variables)
      if let recordingPackageURL, context.recordingPackageURL() == recordingPackageURL {
        context.archiveResult?(id, frame.image, output)
      }
    } catch {
      guard isCurrent() else { return }
      resultsByVisionInternalID.removeValue(forKey: id)
      context.reportFailure(id, error)
    }
  }

  static func ocrConfiguration(for vision: Ldtx_Workspace_V4_OcrVision) -> VisionOCRConfiguration {
    VisionOCRConfiguration(
      recognitionLanguages: vision.recognitionLanguages,
      usesLanguageCorrection: vision.usesLanguageCorrection ?? false,
      customWords: vision.customWords,
      minimumTextHeight: vision.minimumTextHeight?.float(defaultNumerator: 0, defaultDenominator: 1)
        ?? 0)
  }
}
