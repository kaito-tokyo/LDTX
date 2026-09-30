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
    self.component = uiState.definition.videoComponents
      .first(where: { $0.id == videoComponentID })
      .flatMap { wrapper in
        guard case .solidColorFill(let component) = wrapper.definition else { return nil }
        return component
      }
    self._name = State(initialValue: component?.displayName ?? "(invalid)")
    self._color = State(
      initialValue: component?.color.asColor() ?? Color(red: 1, green: 0, blue: 1))
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

      var definition = uiState.definition
      guard let index = definition.videoComponents.firstIndex(where: { $0.id == videoComponentID })
      else { return }
      definition.videoComponents[index].definition = .solidColorFill(component)
      uiState.definition = definition
      uiState.recordDefinitionChange()
    }
  }
}

#if DEBUG
  #Preview("Default") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .solidColorFillVideoComponent, internalID: 4))
    SolidColorFillVideoComponentInspector(
      uiState: uiState, videoComponentID: .solidColorFill(4)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Output Active") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .solidColorFillVideoComponent, internalID: 4), isOutputActive: true)
    SolidColorFillVideoComponentInspector(
      uiState: uiState, videoComponentID: .solidColorFill(4)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Invalid") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .solidColorFillVideoComponent, internalID: 4))
    SolidColorFillVideoComponentInspector(
      uiState: uiState, videoComponentID: .solidColorFill(404)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }
#endif
