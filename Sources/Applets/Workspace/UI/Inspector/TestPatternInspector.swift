// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

struct TestPatternInspector: View {
  let uiState: WorkspaceUIState
  let internalID: UInt64
  let session: (any WorkspaceSessionProtocol)?
  let recordingSession: (any WorkspaceRecordingSessionProtocol)?

  var body: some View {
    Section("Test Pattern") {
      if component != nil {
        TextField("Name", text: nameBinding)
          .disabled(recordingSession?.isRecording ?? false)
      } else {
        Text("This item is no longer present in the Workspace.")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var component: Ldtx_Workspace_V4_TestPatternComponent? {
    uiState.definition.videoComponents.compactMap { wrapper in
      guard case .testPattern(let value) = wrapper.definition,
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
          guard case .testPattern(var value) = wrapper.definition else { return }
          value.displayName = name
          wrapper.definition = .testPattern(value)
        }
      }
    )
  }
  private func updateVideoComponent(
    _ mutation: (inout Ldtx_Workspace_V4_VideoComponentWrapper) -> Void
  ) {
    var definition = uiState.definition
    guard
      let index = definition.videoComponents.firstIndex(where: { wrapper in
        switch wrapper.id {
        case .solidColorFill(let id), .linearGradientFill(let id), .radialGradientFill(let id),
          .conicGradientFill(let id), .vfxSource(let id), .clock(let id), .testPattern(let id):
          id == internalID
        case .invalid:
          false
        }
      })
    else { return }
    mutation(&definition.videoComponents[index])
    uiState.definition = definition
  }

}
