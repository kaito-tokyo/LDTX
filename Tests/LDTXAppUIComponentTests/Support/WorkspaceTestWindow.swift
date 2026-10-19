// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXDeviceRegistry
import LDTXProgramRuntime
@testable import LDTXWorkspaceAppletController
@testable import LDTXWorkspaceAppletUI
import SwiftUI

@MainActor
final class WorkspaceTestWindow: NSWindow {
  let stateService: WorkspaceDocument
  let contentPane: WorkspaceContentPane
  let workspaceDocument: (any WorkspaceDocumentContext)?
  private let runtimeActions: () -> (any WorkspaceRuntimeActions)?
  private var inferenceTask: Task<Void, Never>?

  init(
    stateService: WorkspaceDocument, appletData: WorkspaceAppletData,
    deviceRegistry: DeviceRegistryService, peakMeter: ProgramAudioPeakMeter,
    pairedPreview: ProgramCanvasPairedPreview,
    runtimeActions: @escaping () -> (any WorkspaceRuntimeActions)?,
    document: (any WorkspaceDocumentContext)? = nil
  ) {
    self.stateService = stateService
    self.runtimeActions = runtimeActions
    workspaceDocument = document
    contentPane = WorkspaceContentPane(
      stateService: stateService, appletData: appletData, peakMeter: peakMeter,
      reportError: { stateService.operationErrors.append($0 as NSError) },
      pairedPreview: pairedPreview, runtimeActions: runtimeActions)
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 1062, height: 700),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    pairedPreview.attachWindow = { [weak stateService] _ in
      guard let stateService else { return nil }
      return WorkspaceDocumentActions(stateService: stateService)
    }
    let root = WorkspaceLayout(
      stateService: stateService,
      sidebar: WorkspaceSidebar(
        stateService: stateService, deviceRegistry: deviceRegistry,
        appletData: appletData, document: document, runtimeActions: runtimeActions),
      content: contentPane,
      inspector: WorkspaceInspectorContainer(
        deviceRegistry: deviceRegistry, stateService: stateService, appletData: appletData,
        document: document, runtimeWorkspace: { [weak document] in document?.runtimeWorkspace },
        runtimeActions: runtimeActions)
    )
    .toolbar {
      WorkspaceToolbar(
        stateService: stateService, document: document,
        runtimeWorkspace: { [weak document] in document?.runtimeWorkspace },
        runtimeActions: runtimeActions, runInference: { [weak self] in self?.runInference() })
    }
    .workspaceErrorAlert(stateService: stateService)
    let host = NSHostingController(rootView: root)
    host.sizingOptions = []
    host.sceneBridgingOptions = [.toolbars]
    contentViewController = host
    setContentSize(NSSize(width: 1062, height: 700))
  }

  func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
    item.menuFormRepresentation?.isEnabled ?? false
  }
  func runInference() {
    guard !stateService.isClosed, inferenceTask == nil, let actions = runtimeActions() else {
      return
    }
    inferenceTask = Task { [self] in
      defer { inferenceTask = nil }
      await actions.inferSelectedVision(
        stateService: stateService, document: workspaceDocument,
        runtimeWorkspace: { [weak self] in self?.workspaceDocument?.runtimeWorkspace })
    }
  }
  @discardableResult func captureScreenshots() -> WorkspaceScreenshotResult {
    WorkspaceScreenshotResult.capture(using: runtimeActions())
  }
  func toggleOutput() {
    Task {
      await runtimeActions()?.toggleOutput(stateService: stateService, document: workspaceDocument)
    }
  }
  func stopOutput() {
    guard !stateService.isClosed, stateService.recordingState.canStop else { return }
    Task { await runtimeActions()?.stopOutput() }
  }
  override func close() {
    stateService.isClosed = true
    stateService.operationErrors.removeAll()
    super.close()
  }
}

// swift-format-ignore: AvoidRetroactiveConformances
extension NSDocument: @retroactive WorkspaceDocumentContext {}
