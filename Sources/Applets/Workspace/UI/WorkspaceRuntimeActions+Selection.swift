// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletInterface
import LDTXWorkspaceBundleFormat

extension WorkspaceRuntimeActions {
  @MainActor public func inferSelectedVision(
    stateService: WorkspaceDocument, document: (any WorkspaceDocumentContext)?,
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
    stateService: WorkspaceDocument, document: (any WorkspaceDocumentContext)?
  ) async {
    guard
      WorkspaceOutputControls(
        stateService: stateService, hasSavedURL: document?.fileURL != nil
      ).startPauseEnabled
    else { return }
    let state = stateService.recordingState
    if state == .recording {
      await pauseOutput()
    } else {
      do { try await startOutput() } catch {
        stateService.outputFailureMessage = error.localizedDescription
      }
    }
  }
}

/// Shared toolbar and hardware-button admission. Runtime operations still revalidate.
public struct WorkspaceOutputControls: Equatable, Sendable {
  public let stopEnabled: Bool
  public let startPauseEnabled: Bool
  public let screenshotEnabled: Bool
  public let showsPause: Bool

  public func state(for action: WorkspaceAction, hasRecording: Bool) -> WorkspaceActionState {
    let enabled: Bool
    switch action {
    case .stopOutput: enabled = stopEnabled
    case .startPauseOutput: enabled = startPauseEnabled
    case .captureScreenshots: enabled = screenshotEnabled
    case .showRecordingInFinder: enabled = screenshotEnabled && hasRecording
    }
    return .init(isEnabled: enabled, showsPause: showsPause)
  }

  @MainActor public init(
    stateService: WorkspaceDocument, hasSavedURL: Bool, isClosing: Bool = false
  ) {
    let state = stateService.recordingState
    let available = !stateService.isClosed && !isClosing
    stopEnabled = available && state.canStop
    startPauseEnabled =
      available
      && ((state.canStart && hasSavedURL) || state == .recording)
    screenshotEnabled = available
    showsPause = state == .recording
  }
}
