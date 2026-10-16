// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceBundleFormat

extension WorkspaceRuntimeActions {
  @MainActor public func inferSelectedVision(
    stateService: WorkspaceStateService, document: (any WorkspaceDocumentContext)?,
    runtimeWorkspace: @escaping () -> WorkspaceV4Bundle?
  ) async {
    guard !stateService.isClosed, !stateService.isInferring,
      let request = stateService.inferenceRequest(document: document, workspace: runtimeWorkspace())
    else { return }
    let id = request.vision.internalID
    let editingVision = stateService.workspaceDefinition.visions.first { $0.internalID == id }
    func isCurrent() -> Bool {
      guard !stateService.isClosed,
        let current = stateService.inferenceRequest(
          document: document, workspace: runtimeWorkspace())
      else { return false }
      return current.vision == request.vision && current.url == request.url
        && stateService.workspaceDefinition.visions.first { $0.internalID == id } == editingVision
    }
    stateService.isInferring = true
    stateService.visionResults.removeValue(forKey: id)
    stateService.visionFailureMessages.removeValue(forKey: id)
    defer { stateService.isInferring = false }
    do {
      let result = try await classify(vision: request.vision, modelURL: request.url)
      guard isCurrent() else { return }
      stateService.visionResults[id] = result
    } catch is CancellationError {
      return
    } catch {
      guard isCurrent() else { return }
      stateService.visionFailureMessages[id] = error.localizedDescription
    }
  }

  @MainActor public func toggleOutput(
    stateService: WorkspaceStateService, document: (any WorkspaceDocumentContext)?
  ) async {
    guard !stateService.isClosed else { return }
    let state = stateService.recordingState
    guard (state.canStart && document?.fileURL != nil) || state == .recording else { return }
    if state == .recording {
      await pauseOutput()
    } else {
      do { try await startOutput() } catch {
        stateService.outputFailureMessage = error.localizedDescription
      }
    }
  }
}
