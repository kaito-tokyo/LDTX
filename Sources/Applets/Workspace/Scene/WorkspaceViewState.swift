// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXDeviceRegistry
import LDTXProgramRuntime
import LDTXProtos
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import Observation
import SwiftUI

@MainActor @Observable
public final class WorkspaceViewState {
  weak var document: (any WorkspaceDocumentContext)?
  let appletData: WorkspaceAppletData
  let stateService: WorkspaceStateService
  let runtimeActions: () -> (any WorkspaceRuntimeActions)?
  let runtimeWorkspace: () -> WorkspaceV4Bundle?
  let reportError: (Error) -> Void
  let deviceRegistry: DeviceRegistryService

  let layout = WorkspacePaneLayout()
  let contentLayout = WorkspaceContentLayout()
  let peakMeter: ProgramAudioPeakMeter
  let pairedPreview: ProgramCanvasPairedPreview

  let presentation = WorkspacePresentation()
  @ObservationIgnored private var inferenceTask: Task<Void, Never>?
  private(set) var isClosed = false

  init(
    document: any WorkspaceDocumentContext,
    appletData: WorkspaceAppletData,
    stateService: WorkspaceStateService,
    peakMeter: ProgramAudioPeakMeter,
    reportError: @escaping (Error) -> Void,
    deviceRegistry: DeviceRegistryService,
    pairedPreview: ProgramCanvasPairedPreview,
    runtimeActions: @escaping () -> (any WorkspaceRuntimeActions)? = { nil },
    runtimeWorkspace: (() -> WorkspaceV4Bundle?)? = nil
  ) {
    self.document = document
    self.appletData = appletData
    self.stateService = stateService
    self.runtimeActions = runtimeActions
    self.runtimeWorkspace = runtimeWorkspace ?? { [weak document] in document?.runtimeWorkspace }
    self.reportError = reportError
    self.deviceRegistry = deviceRegistry

    self.peakMeter = peakMeter
    self.pairedPreview = pairedPreview
    pairedPreview.attachWindow = { [weak self] window in
      self?.didAttachWindow?(window)
      guard let self else { return nil }
      return WorkspaceDocumentActions(state: self)
    }
  }

  var didAttachWindow: ((NSWindow?) -> Void)?

  private var operationErrorDismissed: (() -> Void)?

  func presentOperationError(_ error: NSError, onDismiss: @escaping () -> Void) {
    presentation.operationError = error
    operationErrorDismissed = onDismiss
  }

  func dismissOperationError() {
    presentation.operationError = nil
    let dismissed = operationErrorDismissed
    operationErrorDismissed = nil
    dismissed?()
  }

  func toggleSidebar() {
    stateService.isSidebarVisible.toggle()
  }

  func toggleInspector() {
    stateService.isInspectorVisible.toggle()
  }

  var inferenceRequest: (vision: Ldtx_Workspace_V4_LdtxSceneDetectorVision, url: URL)? {
    guard stateService.inspectorSelector?.kind == .ldtxSceneDetectorVision,
      let workspace = runtimeWorkspace(),
      document?.fileURL != nil,
      let id = stateService.inspectorSelector?.internalID,
      let vision = workspace.definition.visions.compactMap({
        wrapper -> Ldtx_Workspace_V4_LdtxSceneDetectorVision? in
        if case .ldtxSceneDetectorVision(let vision)? = wrapper.vision,
          vision.internalID == id
        {
          return vision
        }
        return nil
      }).first,
      vision.modelInternalID > 0,
      stateService.workspaceDefinition.visions.contains(where: {
        $0.vision == .ldtxSceneDetectorVision(vision)
      }),
      workspace.definition.videoComponents.contains(where: {
        $0.internalID == vision.videoComponentInternalID && $0.canBeVisionInput
          && $0.renderingSize != nil
      })
    else { return nil }
    guard let url = workspace.visionModels[vision.modelInternalID] else { return nil }
    return (vision, url)
  }

  func runInference() {
    guard !isClosed, inferenceTask == nil, let request = inferenceRequest,
      let actions = runtimeActions()
    else { return }
    let id = request.vision.internalID
    let editingVision = stateService.workspaceDefinition.visions.first { $0.internalID == id }
    stateService.visionResults.removeValue(forKey: id)
    stateService.visionFailureMessages.removeValue(forKey: id)
    inferenceTask = Task { [weak self] in
      guard let self else { return }
      defer {
        inferenceTask = nil
        presentation.isInferring = false
      }
      do {
        let result = try await actions.classify(vision: request.vision, modelURL: request.url)
        guard !isClosed, let current = inferenceRequest,
          stateService.workspaceDefinition.visions.first(where: { $0.internalID == id })
            == editingVision,
          current.vision == request.vision, current.url == request.url
        else { return }
        stateService.visionResults[id] = result
      } catch {
        guard !isClosed, let current = inferenceRequest,
          stateService.workspaceDefinition.visions.first(where: { $0.internalID == id })
            == editingVision,
          current.vision == request.vision, current.url == request.url
        else { return }
        stateService.visionFailureMessages[id] = error.localizedDescription
      }
    }

    presentation.isInferring = true
  }

  func captureScreenshots() {
    guard !isClosed else { return }
    do {
      guard let runtimeActions = runtimeActions() else {
        throw WorkspaceSelectionError(message: "Workspace runtime is unavailable.")
      }
      let files = try runtimeActions.captureScreenshots()
      let programFiles = files.filter { $0.programCanvas != nil }
      showScreenshotResult(
        title: "Screenshots saved",
        message: programFiles.isEmpty
          ? "No Program screenshots were available."
          : programFiles.count == 1
            ? "Saved 1 Program screenshot." : "Saved \(programFiles.count) Program screenshots.",
        screenshots: programFiles.filter { $0.programCanvas == .landscape })
    } catch {
      showScreenshotResult(
        title: "Screenshot could not be captured", message: error.localizedDescription)
    }
  }

  private func showScreenshotResult(
    title: String, message: String, screenshots: [WorkspaceScreenshot] = []
  ) {
    presentation.screenshot = WorkspaceScreenshotPresentation(
      title: title, message: message, screenshots: screenshots)
  }

  func waitForInference() async {
    await inferenceTask?.value
  }

  func tearDown() {
    isClosed = true
    presentation.screenshot = nil
    dismissOperationError()
  }

  func stopOutput() {
    guard !isClosed, stateService.recordingState.canStop else { return }
    Task { await runtimeActions()?.stopOutput() }
  }

  func toggleOutput() {
    guard !isClosed else { return }
    let state = stateService.recordingState
    guard (state.canStart && document?.fileURL != nil) || state == .recording else { return }
    Task {
      if state == .recording {
        await runtimeActions()?.pauseOutput()
      } else {
        do {
          guard let runtimeActions = runtimeActions() else {
            throw WorkspaceSelectionError(message: "Workspace runtime is unavailable.")
          }
          try await runtimeActions.startOutput()
        } catch {
          stateService.outputFailureMessage = error.localizedDescription
        }
      }
    }
  }
}

@MainActor @Observable
final class WorkspacePresentation {
  var operationError: NSError?
  var isInferring = false
  var screenshot: WorkspaceScreenshotPresentation?
}

struct WorkspaceScreenshotPresentation: Identifiable {
  let id = UUID()
  let title: String
  let message: String
  let screenshots: [WorkspaceScreenshot]
}

