// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletUI
import SwiftUI

struct WorkspaceRootView: View {
  let state: WorkspaceViewState

  var body: some View {
    WorkspacePanes(
      layout: state.layout, stateService: state.stateService,
      sidebar: WorkspaceSidebar(
        stateService: state.stateService, deviceRegistry: state.deviceRegistry,
        appletData: state.appletData, document: state.document, runtimeActions: state.runtimeActions
      ),
      content: contentPane,
      inspector: WorkspaceInspectorContainer(
        deviceRegistry: state.deviceRegistry, stateService: state.stateService,
        appletData: state.appletData, document: state.document,
        runtimeWorkspace: state.runtimeWorkspace, runtimeActions: state.runtimeActions
      )
    )
    .environment(\.workspaceReportError, state.reportError)
    .toolbar { WorkspaceToolbar(state: state) }
    .alert(
      state.presentation.operationError?.localizedDescription ?? "",
      isPresented: Binding(
        get: { state.presentation.operationError != nil },
        set: { if !$0 { state.dismissOperationError() } })
    ) {
      Button("OK") {}
    } message: {
      if let error = state.presentation.operationError {
        Text([error.localizedFailureReason, error.localizedRecoverySuggestion]
          .compactMap { $0 }.joined(separator: "\n\n"))
      }
    }
  }

  var contentPane: WorkspaceContentPane {
    WorkspaceContentPane(
      stateService: state.stateService, appletData: state.appletData,
      peakMeter: state.peakMeter, reportError: state.reportError,
      pairedPreview: state.pairedPreview, runtimeActions: state.runtimeActions,
      layout: state.contentLayout)
  }
}

