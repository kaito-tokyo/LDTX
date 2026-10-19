// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

struct TestPatternInspector: View {
  @Environment(\.undoManager) private var undoManager
  let stateService: WorkspaceDocument
  let appletData: WorkspaceAppletData
  let internalID: Int64

  var body: some View {
    Form {
      VideoComponentProgramLayers(
        stateService: stateService, appletData: appletData, componentID: internalID)
      formContent
      VideoComponentDeleteButton(stateService: stateService, componentID: internalID)
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private var formContent: some View {
    Section("Test Pattern") {
      if component != nil {
        TextField("Name", text: nameBinding)
          .disabled(stateService.isOutputActive)
      } else {
        Text("This item is no longer present in the Workspace.")
          .foregroundStyle(.secondary)
      }
    }

  }

  private var component: Ldtx_Workspace_V4_TestPatternComponent? {
    stateService.workspaceDefinition.videoComponents.compactMap { wrapper in
      guard case .testPattern(let value) = wrapper.videoComponent,
        value.internalID == internalID
      else { return nil }
      return value
    }.first
  }

  private var nameBinding: Binding<String> {
    Binding(
      get: { component?.displayName ?? "" },
      set: { name in
        updateVideoComponent { wrapper in
          guard case .testPattern(var value) = wrapper.videoComponent else { return }
          value.displayName = name
          wrapper.videoComponent = .testPattern(value)
        }
      }
    )
  }
  private func updateVideoComponent(
    _ mutation: (inout Ldtx_Workspace_V4_VideoComponentWrapper) -> Void
  ) {
    var definition = stateService.workspaceDefinition
    guard
      let index = definition.videoComponents.firstIndex(where: { $0.internalID == internalID })
    else { return }
    mutation(&definition.videoComponents[index])
    stateService.editWorkspace(undoManager: undoManager) { workspace in
      workspace.definition = definition
    }
  }

}
