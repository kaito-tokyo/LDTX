// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletUI
import SwiftUI

public struct WorkspaceDocumentContent: View {
  @State private var connection: WorkspaceDocumentConnection?
  let document: WorkspaceDocument
  @Environment(\.workspaceAppletDelegate) private var appletDelegate

  public init(document: WorkspaceDocument) {
    self.document = document
  }

  public var body: some View {
    ZStack {
      if let connection { workspace(connection.runtimeCoordinator) }
    }
    .frame(minWidth: document.stateService.minimumWindowWidth, minHeight: 400)
    .focusedSceneValue(\.workspaceUndoDisabled, document.stateService.isOutputActive)
    .focusedSceneValue(\.streamDeckWorkspace, connection?.runtimeCoordinator)
    .task {
      guard !document.stateService.isClosed else { return }
      guard let appletDelegate else {
        preconditionFailure(
          "WorkspaceAppletDelegate must be injected at the application entry point")
      }
      if connection == nil {
        let coordinator = appletDelegate.workspaceCoordinator(for: document)
        connection =
          coordinator.documentConnection
          ?? WorkspaceDocumentConnection(
            document: document, runtimeCoordinator: coordinator)
      }
    }
  }

  private func workspace(_ runtime: WorkspaceAppletCoordinator) -> some View {
    let stateService = document.stateService
    let actions: () -> (any WorkspaceRuntimeActions)? = { [weak runtime] in
      guard !stateService.isClosed else { return nil }
      return runtime
    }
    let persistedWorkspace = { [weak runtime] in runtime?.windowRuntime.workspace }
    return WorkspaceLayout(
      stateService: stateService,
      sidebar: WorkspaceSidebar(
        stateService: stateService, deviceRegistry: runtime.deviceRegistry,
        appletData: runtime.appletData, document: document, runtimeActions: actions),
      content: WorkspaceContentPane(
        stateService: stateService, appletData: runtime.appletData, peakMeter: runtime.peakMeter,
        reportError: { [weak runtime] in runtime?.reportError($0) },
        pairedPreview: runtime.pairedPreview, runtimeActions: actions),
      inspector: WorkspaceInspectorContainer(
        deviceRegistry: runtime.deviceRegistry, stateService: stateService,
        appletData: runtime.appletData, document: document,
        variableStore: { [weak runtime] in runtime?.windowRuntime.variableStore },
        runtimeWorkspace: persistedWorkspace, runtimeActions: actions)
    )
    .environment(\.workspaceReportError, { [weak runtime] in runtime?.reportError($0) })
    .toolbar {
      WorkspaceToolbar(
        stateService: stateService, document: document, runtimeWorkspace: persistedWorkspace,
        runtimeActions: actions, runInference: { [weak runtime] in runtime?.runInference() })
    }
    .workspaceErrorAlert(stateService: stateService)
  }
}
