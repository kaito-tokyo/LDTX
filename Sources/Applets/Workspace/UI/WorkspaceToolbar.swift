// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import LDTXWorkspaceBundleFormat
import SwiftUI

public struct WorkspaceToolbar: ToolbarContent {
  let stateService: WorkspaceDocument
  let document: (any WorkspaceDocumentContext)?
  let runtimeWorkspace: () -> WorkspaceV4Bundle?
  let runtimeActions: () -> (any WorkspaceRuntimeActions)?
  let runInference: () -> Void

  public init(
    stateService: WorkspaceDocument, document: (any WorkspaceDocumentContext)?,
    runtimeWorkspace: @escaping () -> WorkspaceV4Bundle?,
    runtimeActions: @escaping () -> (any WorkspaceRuntimeActions)?,
    runInference: @escaping () -> Void
  ) {
    self.stateService = stateService
    self.document = document
    self.runtimeWorkspace = runtimeWorkspace
    self.runtimeActions = runtimeActions
    self.runInference = runInference
  }

  public var body: some ToolbarContent {
    ToolbarItem(id: "workspace.toggleSidebar", placement: .navigation) {
      Button("Toggle Sidebar", systemImage: "sidebar.left") {
        stateService.isSidebarVisible.toggle()
      }
      .accessibilityIdentifier("workspace.toggleSidebar")
    }
    ForEach(WorkspaceAction.allCases, id: \.self) { action in
      ToolbarItem(id: "workspace.\(action.rawValue)", placement: .navigation) {
        WorkspaceActionButton(
          action: action, runtimeActions: runtimeActions)
      }
    }
    ToolbarItem(id: "workspace.runInference", placement: .primaryAction) {
      Button("Run Inference", systemImage: "sparkles", action: runInference)
        .disabled(
          stateService.isClosed || stateService.isInferring || runtimeActions() == nil
            || stateService.inferenceRequest(document: document, workspace: runtimeWorkspace())
              == nil
        )
        .accessibilityIdentifier("workspace.runInference")
    }
    ToolbarItem(id: "workspace.toggleInspector", placement: .primaryAction) {
      Button("Toggle Inspector", systemImage: "sidebar.right") {
        stateService.isInspectorVisible.toggle()
      }
      .accessibilityIdentifier("workspace.toggleInspector")
    }
  }
}

private struct WorkspaceActionButton: View {
  let action: WorkspaceAction
  let runtimeActions: () -> (any WorkspaceRuntimeActions)?

  var body: some View {
    let state = runtimeActions()?.actionState(action) ?? .init(isEnabled: false)
    Button(
      action.title(showsPause: state.showsPause),
      systemImage: action.systemImage(showsPause: state.showsPause)
    ) {
      Task { await runtimeActions()?.perform(action) }
    }
    .disabled(!state.isEnabled)
    .accessibilityIdentifier("workspace.\(action.rawValue)")
  }
}
