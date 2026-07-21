// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXInternalProtocols
import LDTXTaskQueue
import LDTXWorkspace

@MainActor
final class WorkspaceVisionFeature {
  private let unavailablePresenter = UnavailableVisionRuntimePresenter()

  var presenter: any VisionRuntimePresenting { unavailablePresenter }

  func synchronize(
    visions _: [WorkspaceVisionDefinition],
    taskQueue _: SessionTaskQueue,
    context _: WorkspaceVisionFeatureContext
  ) {}

  func stop() {}

  func submit(
    _ vision: WorkspaceVisionDefinition,
    source _: SessionTaskSubmission,
    taskQueue _: SessionTaskQueue,
    context: WorkspaceVisionFeatureContext
  ) {
    context.appendLog("Vision '\(vision.name)' is unavailable in this app target.")
  }

  func perform(
    _ vision: WorkspaceVisionDefinition,
    context _: WorkspaceVisionFeatureContext,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  ) {
    completion(.failure(WorkspaceVisionFeatureError.unavailable))
  }
}
