// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXAppCore
import LDTXInternalProtocols
import LDTXTaskQueue
import LDTXVision
import LDTXWorkspace

@MainActor
public final class WorkspaceVisionFeature: WorkspaceVisionFeatureProviding {
  private let runtimeStore = VisionRuntimeStore()
  private let recordingArchive = VisionRecordingArchive()
  private let framePool = VisionFramePool()
  private let ocrFrameCopier = VisionOCRFrameCopier()
  private let workspaceResourceQueue: WorkspaceResourceQueue
  private var analysisTaskQueue: BackgroundTaskQueue?
  private var updateTasks: [String: DispatchSourceTimer] = [:]
  private var analysisTasks: [String: Task<Void, Never>] = [:]

  public init(workspaceResourceQueue: WorkspaceResourceQueue) {
    self.workspaceResourceQueue = workspaceResourceQueue
    let runtimeStore = self.runtimeStore
    workspaceResourceQueue.registerCleanup(key: WorkspaceResourceKey("vision")) {
      await withCheckedContinuation { continuation in
        Task { @MainActor [runtimeStore] in
          runtimeStore.removeAllModels { continuation.resume() }
        }
      }
    }
  }

  public var presenter: any VisionRuntimePresenting { runtimeStore }

  public func synchronizeModels(visions: [WorkspaceVisionDefinition]) {
    var modelsByKey: [String: WorkspaceVisionModel] = [:]
    for vision in visions {
      guard case .visionLanguageModel(let definition) = vision.definition else { continue }
      modelsByKey[modelLoadingKey(definition.model)] = definition.model
    }
    for model in modelsByKey.values {
      submitModelLoad(model)
    }
  }

  public func synchronize(
    visions: [WorkspaceVisionDefinition],
    context: WorkspaceVisionFeatureContext
  ) {
    _ = backgroundAnalysisTaskQueue()
    runtimeStore.synchronize(visions: visions)
    updateTasks.values.forEach { $0.cancel() }
    updateTasks.removeAll()
    for vision in visions {
      guard let seconds = vision.updateIntervalSeconds, seconds > 0 else { continue }
      let scheduledInterval = max(
        seconds, WorkspaceVisionDefinition.minimumUpdateIntervalSeconds)
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.schedule(deadline: .now() + scheduledInterval, repeating: scheduledInterval)
      timer.setEventHandler { [weak self] in
        guard context.isSessionRunning(),
          let current = context.visionNamed(vision.id),
          current.updateIntervalSeconds != nil
        else {
          return
        }
        self?.submit(current, source: .periodic, context: context)
      }
      timer.resume()
      updateTasks[vision.id] = timer
    }
  }

  public func stop(completion: @escaping @MainActor @Sendable () -> Void = {}) {
    stopAnalysis(completion: completion)
  }

  public func stopAnalysis(completion: @escaping @MainActor @Sendable () -> Void = {}) {
    updateTasks.values.forEach { $0.cancel() }
    updateTasks.removeAll()
    let tasks = Array(analysisTasks.values)
    analysisTasks.removeAll()
    guard let taskQueue = analysisTaskQueue else {
      tasks.forEach { $0.cancel() }
      completion()
      return
    }
    taskQueue.stop { [weak self] in
      if self?.analysisTaskQueue === taskQueue {
        self?.analysisTaskQueue = nil
      }
      completion()
    }
    tasks.forEach { $0.cancel() }
  }

  public func submit(
    _ vision: WorkspaceVisionDefinition,
    source: BackgroundTaskSubmission,
    context: WorkspaceVisionFeatureContext
  ) {
    guard context.isSessionRunning() else { return }
    guard source != .manual || vision.updateIntervalSeconds == nil else { return }
    let taskQueue = backgroundAnalysisTaskQueue()
    taskQueue.submit(key: BackgroundTaskKey("vision:\(vision.id)"), source: source) { finish in
      { stopToken in
        Task { @MainActor in
          guard !stopToken.isStopRequested,
            context.isSessionRunning(),
            context.visionNamed(vision.id) == vision
          else {
            finish()
            return
          }
          self.perform(vision, stopToken: stopToken, context: context) { _ in finish() }
        }
      }
    }
  }

  public func perform(
    _ vision: WorkspaceVisionDefinition,
    stopToken: StopToken,
    context: WorkspaceVisionFeatureContext,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  ) {
    guard context.isSessionRunning() else {
      completion(.failure(WorkspaceVisionFeatureError.sessionNotRunning))
      return
    }
    guard !stopToken.isStopRequested else {
      completion(.failure(TaskQueueStopped()))
      return
    }
    let frame: WorkspaceVisionAnalysisFrame
    do {
      frame = try context.frameForVision(vision)
    } catch {
      runtimeStore.reportAcquisitionFailure(for: vision.id, message: error.localizedDescription)
      completion(.failure(error))
      return
    }
    // Keep both the archive position and package lifetime tied to the frame
    // being analyzed. VLM inference can outlive a Cut finalizer.
    let recordingLease = context.beginRecordingOperation()
    let finish: @MainActor (Result<Void, Error>) -> Void = { result in
      recordingLease?.release()
      completion(result)
    }
    let snapshot: VisionFrameSnapshot?
    switch vision.definition {
    case .visionLanguageModel:
      snapshot = framePool.copy(image: frame.image)
    case .opticalCharacterRecognition(let definition):
      snapshot = ocrFrameCopier.copy(
        image: frame.image,
        subsamplingRate: definition.subsamplingRate
      )
    }
    guard let snapshot else {
      let error = WorkspaceVisionFeatureError.framePoolBusy
      runtimeStore.reportAcquisitionFailure(for: vision.id, message: error.localizedDescription)
      finish(.failure(error))
      return
    }
    if let gate = vision.histogramGate {
      let gateTask = Task.detached(priority: .utility) {
        VisionHistogramGate.accepts(
          pixelBuffer: snapshot.pixelBuffer,
          configuration: gate,
          isCancellationRequested: { stopToken.isStopRequested }
        )
      }
      Task { @MainActor [self] in
        let isOpen = await gateTask.value
        guard !stopToken.isStopRequested else {
          finish(.failure(TaskQueueStopped()))
          return
        }
        guard context.isSessionRunning(), context.visionNamed(vision.id) == vision else {
          finish(.failure(WorkspaceVisionFeatureError.definitionChanged))
          return
        }
        guard isOpen else {
          // A closed gate is an expected no-op. Keep the last accepted result
          // and availability status, and do not archive an unanalyzed frame.
          runtimeStore.clearAcquisitionFailure(for: vision)
          finish(.success(()))
          return
        }
        beginAnalysis(
          vision,
          snapshot: snapshot,
          recordingLease: recordingLease,
          stopToken: stopToken,
          context: context,
          completion: finish
        )
      }
      return
    }
    beginAnalysis(
      vision,
      snapshot: snapshot,
      recordingLease: recordingLease,
      stopToken: stopToken,
      context: context,
      completion: finish
    )
  }

  private func beginAnalysis(
    _ vision: WorkspaceVisionDefinition,
    snapshot: VisionFrameSnapshot,
    recordingLease: WorkspaceVisionRecordingLease?,
    stopToken: StopToken,
    context: WorkspaceVisionFeatureContext,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  ) {
    let task = runtimeStore.performAnalyze(
      vision,
      image: snapshot.image,
      stopToken: stopToken
    ) { [self] result in
      analysisTasks[vision.id] = nil
      guard !stopToken.isStopRequested else {
        if let current = context.visionNamed(vision.id) {
          runtimeStore.discardOperation(for: current)
        }
        completion(.failure(TaskQueueStopped()))
        return
      }
      switch result {
      case .success(let analysis):
        guard let current = context.visionNamed(vision.id), current == vision else {
          if let current = context.visionNamed(vision.id) {
            runtimeStore.discardOperation(for: current)
          }
          completion(.failure(WorkspaceVisionFeatureError.definitionChanged))
          return
        }
        if let recordingLease {
          Task {
            let artifact: VisionRecordingArtifact
            do {
              guard let timelineMilliseconds = recordingLease.timelineMilliseconds else {
                throw VisionRecordingArchiveError.invalidTimelineTimestamp
              }
              artifact = try await recordingArchive.saveThrowing(
                image: snapshot.image,
                vision: current,
                analysis: analysis,
                recordingPackageDirectory: recordingLease.packageDirectory,
                timelineMilliseconds: timelineMilliseconds
              )
            } catch {
              await MainActor.run {
                if stopToken.isStopRequested {
                  runtimeStore.discardOperation(for: current)
                } else if let latest = context.visionNamed(vision.id), latest != vision {
                  runtimeStore.discardOperation(for: latest)
                } else {
                  runtimeStore.reportFailure(
                    for: vision.id,
                    message: error.localizedDescription
                  )
                  context.presentRecordingFailure(error)
                }
                completion(.failure(error))
              }
              return
            }
            let accepted = await MainActor.run {
              guard !stopToken.isStopRequested,
                context.visionNamed(vision.id) == vision
              else {
                if let current = context.visionNamed(vision.id) {
                  runtimeStore.discardOperation(for: current)
                }
                return false
              }
              runtimeStore.accept(analysis, for: vision)
              completion(.success(()))
              return true
            }
            if !accepted {
              await recordingArchive.remove(artifact)
              await MainActor.run {
                completion(.failure(WorkspaceVisionFeatureError.definitionChanged))
              }
            }
          }
        } else {
          runtimeStore.accept(analysis, for: current)
          completion(.success(()))
        }
      case .failure(let error):
        if let current = context.visionNamed(vision.id) {
          if current == vision {
            runtimeStore.reportFailure(for: vision.id, message: error.localizedDescription)
          } else {
            runtimeStore.discardOperation(for: current)
          }
        }
        completion(.failure(error))
      }
    }
    analysisTasks[vision.id] = task
  }

  private func backgroundAnalysisTaskQueue() -> BackgroundTaskQueue {
    if let analysisTaskQueue { return analysisTaskQueue }
    let taskQueue = BackgroundTaskQueue(label: "tokyo.kaito.ldtx.workspace.vision")
    analysisTaskQueue = taskQueue
    return taskQueue
  }

  private func submitModelLoad(_ model: WorkspaceVisionModel) {
    let key = modelLoadingKey(model)
    let runtimeStore = self.runtimeStore
    workspaceResourceQueue.enqueue(key: WorkspaceResourceKey("vision-model:\(key)")) {
      await withCheckedContinuation { continuation in
        Task { @MainActor [runtimeStore] in
          runtimeStore.loadModel(model) { _ in
            continuation.resume()
          }
        }
      }
    }
  }

  private func modelLoadingKey(_ model: WorkspaceVisionModel) -> String {
    "\(model.repositoryID)\u{0}\(model.revision ?? "")"
  }
}
