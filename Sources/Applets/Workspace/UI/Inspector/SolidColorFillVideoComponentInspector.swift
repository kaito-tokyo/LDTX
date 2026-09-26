// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

struct SolidColorFillVideoComponentInspector: View {
  let uiState: WorkspaceUIState
  let videoComponentID: WorkspaceUIState.VideoComponentWrapper.ID

  private let component: Ldtx_Workspace_V4_FillSolidColorComponent?

  @State private var name: String
  @State private var color: Color

  init(uiState: WorkspaceUIState, videoComponentID: WorkspaceUIState.VideoComponentWrapper.ID) {
    self.uiState = uiState
    self.videoComponentID = videoComponentID
    self.component = uiState.findVideoComponent(id: videoComponentID)
    self._name = State(initialValue: component?.displayName ?? "(invalid)")
    self._color = State(initialValue: component?.color.asColor() ?? Color(red: 1, green: 0, blue: 1))
  }

  var body: some View {
    Form {
      Section("Solid Color Fill") {
        HStack(alignment: .center, spacing: 4) {
          Rectangle()
            .fill(color)
            .aspectRatio(16 / 9, contentMode: .fit)
          Rectangle()
            .fill(color)
            .aspectRatio(9 / 16, contentMode: .fit)
        }
        .aspectRatio(16 / 9 + 9 / 16, contentMode: .fit)

        TextField("Name", text: $name)

        ColorPicker("Color", selection: $color, supportsOpacity: true)
      }
    }
    .formStyle(.grouped)
    .disabled(uiState.isOutputActive || component == nil)
    .onSubmit {
      guard
        var component = self.component,
        let nsColor = NSColor(color).usingColorSpace(.sRGB)
      else { return }

      component.displayName = name
      component.color.red = Float(nsColor.redComponent)
      component.color.green = Float(nsColor.greenComponent)
      component.color.blue = Float(nsColor.blueComponent)
      component.color.alpha = Float(nsColor.alphaComponent)

      uiState.replaceVideoComponent(
        id: videoComponentID,
        with: .solidColorFill(component))
    }
  }
}

#if DEBUG
  #Preview("Default") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorKind: .solidColorFillVideoComponent(4))
    SolidColorFillVideoComponentInspector(
      uiState: uiState, videoComponentID: .solidColorFill(4)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Output Active") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorKind: .solidColorFillVideoComponent(4), isOutputActive: true)
    SolidColorFillVideoComponentInspector(
      uiState: uiState, videoComponentID: .solidColorFill(4)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Invalid") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorKind: .solidColorFillVideoComponent(404))
    SolidColorFillVideoComponentInspector(
      uiState: uiState, videoComponentID: .solidColorFill(404)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }
#endif
