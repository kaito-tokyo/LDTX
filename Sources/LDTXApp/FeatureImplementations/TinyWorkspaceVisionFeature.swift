// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXInternalProtocols
import LDTXTaskQueue
import LDTXWorkspace

@MainActor
final class WorkspaceVisionFeature {
  private let unavailablePresenter = UnavailableVisionRuntimePresenter()

  init(workspaceResourceQueue _: WorkspaceResourceQueue) {}

  var presenter: any VisionRuntimePresenting { unavailablePresenter }

  func synchronizeModels(visions _: [WorkspaceVisionDefinition]) {}

  func synchronize(
    visions _: [WorkspaceVisionDefinition],
    context _: WorkspaceVisionFeatureContext
  ) {}

  func stop(completion: @escaping @MainActor @Sendable () -> Void = {}) { completion() }

  func stopAnalysis(completion: @escaping @MainActor @Sendable () -> Void = {}) { completion() }

  func submit(
    _ vision: WorkspaceVisionDefinition,
    source _: BackgroundTaskSubmission,
    context: WorkspaceVisionFeatureContext
  ) {
    context.appendLog("Vision '\(vision.name)' is unavailable in this app target.")
  }

  func perform(
    _ vision: WorkspaceVisionDefinition,
    stopToken _: StopToken,
    context _: WorkspaceVisionFeatureContext,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  ) {
    completion(.failure(WorkspaceVisionFeatureError.unavailable))
  }
}
