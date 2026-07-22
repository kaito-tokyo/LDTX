// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXInternalProtocols
import LDTXTaskQueue
import LDTXVision
import LDTXWorkspace

@MainActor
final class WorkspaceVisionFeature {
  private let runtimeStore = VisionRuntimeStore()
  private let recordingArchive = VisionRecordingArchive()
  private let framePool = VisionFramePool()
  private var updateTasks: [String: DispatchSourceTimer] = [:]

  var presenter: any VisionRuntimePresenting { runtimeStore }

  func synchronize(
    visions: [WorkspaceVisionDefinition],
    taskQueue: SessionTaskQueue,
    context: WorkspaceVisionFeatureContext
  ) {
    runtimeStore.synchronize(visions: visions)
    updateTasks.values.forEach { $0.cancel() }
    updateTasks.removeAll()
    for vision in visions {
      guard let seconds = vision.updateIntervalSeconds, seconds > 0 else { continue }
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.schedule(deadline: .now() + max(seconds, 0.1), repeating: max(seconds, 0.1))
      timer.setEventHandler { [weak self] in
        guard let current = context.visionNamed(vision.id), current.updateIntervalSeconds != nil else {
          return
        }
        self?.submit(current, source: .whenIdle, taskQueue: taskQueue, context: context)
      }
      timer.resume()
      updateTasks[vision.id] = timer
    }
  }

  func stop() {
    updateTasks.values.forEach { $0.cancel() }
    updateTasks.removeAll()
  }

  func submit(
    _ vision: WorkspaceVisionDefinition,
    source: SessionTaskSubmission,
    taskQueue: SessionTaskQueue,
    context: WorkspaceVisionFeatureContext
  ) {
    taskQueue.submit(key: SessionTaskKey("vision:\(vision.id)"), source: source) { finish in
      { stopToken in
        Task { @MainActor in
          guard !stopToken.isStopRequested, context.visionNamed(vision.id) == vision else {
            finish()
            return
          }
          self.perform(vision, context: context) { result in
            defer { finish() }
            guard !stopToken.isStopRequested, case .success = result,
              let current = context.visionNamed(vision.id), current == vision,
              let automationName = current.postActionAutomationName
            else { return }
            guard let automation = context.automationNamed(automationName ?? ""), automation.isEnabled else {
              context.appendLog(
                "Vision '\(current.name)' references a missing or disabled Post Action Automation.")
              return
            }
            context.submitAutomation(automation, .normal)
          }
        }
      }
    }
  }

  func perform(
    _ vision: WorkspaceVisionDefinition,
    context: WorkspaceVisionFeatureContext,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  ) {
    let image: CIImage
    do {
      image = try context.imageForVision(vision)
    } catch {
      runtimeStore.reportFailure(for: vision.id, message: error.localizedDescription)
      completion(.failure(error))
      return
    }
    guard let snapshot = framePool.copy(image: image) else {
      let error = WorkspaceVisionFeatureError.framePoolBusy
      runtimeStore.reportFailure(for: vision.id, message: error.localizedDescription)
      completion(.failure(error))
      return
    }
    runtimeStore.performAnalyze(vision, image: snapshot.image) { [self] result in
      switch result {
      case .success(let analysis):
        guard let current = context.visionNamed(vision.id), current == vision else {
          if let current = context.visionNamed(vision.id) {
            runtimeStore.discardOperation(for: current)
          }
          completion(.failure(WorkspaceVisionFeatureError.definitionChanged))
          return
        }
        if let recordingDirectory = context.recordingPackageDirectory() {
          Task {
            let artifact = await recordingArchive.save(
              image: snapshot.image,
              vision: current,
              analysis: analysis,
              recordingPackageDirectory: recordingDirectory
            )
            let accepted = await MainActor.run {
              guard context.visionNamed(vision.id) == vision else {
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
              if let artifact { await recordingArchive.remove(artifact) }
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
  }
}
