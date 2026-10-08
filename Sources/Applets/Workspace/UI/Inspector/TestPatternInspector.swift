// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

struct TestPatternInspector: View {
  let storeService: WorkspaceStoreService
  let internalID: UInt64

  var body: some View {
    Form {
      VideoComponentProgramLayers(storeService: storeService, componentID: .testPattern(internalID))
      formContent
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private var formContent: some View {
    Section("Test Pattern") {
      if component != nil {
        TextField("Name", text: nameBinding)
          .disabled(storeService.isOutputActive)
      } else {
        Text("This item is no longer present in the Workspace.")
          .foregroundStyle(.secondary)
      }
    }

  }

  private var component: Ldtx_Workspace_V4_TestPatternComponent? {
    storeService.definition.videoComponents.compactMap { wrapper in
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
    var definition = storeService.definition
    guard
      let index = definition.videoComponents.firstIndex(where: { $0.internalID == internalID })
    else { return }
    mutation(&definition.videoComponents[index])
    storeService.definition = definition
  }

}
