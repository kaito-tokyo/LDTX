// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import LDTXProtosMacOSExtra
import SwiftUI

struct SolidColorFillVideoComponentInspector: View {
  let storeService: WorkspaceStoreService
  let videoComponentID: WorkspaceStoreService.VideoComponentWrapper.ID

  private let component: Ldtx_Workspace_V4_FillSolidColorComponent?

  @State private var name: String
  @State private var color: Color

  init(
    storeService: WorkspaceStoreService,
    videoComponentID: WorkspaceStoreService.VideoComponentWrapper.ID
  ) {
    self.storeService = storeService
    self.videoComponentID = videoComponentID
    self.component = storeService.definition.videoComponents
      .first(where: { $0.id == videoComponentID })
      .flatMap { wrapper in
        guard case .solidColorFill(let component) = wrapper.videoComponent else { return nil }
        return component
      }
    self._name = State(initialValue: component?.displayName ?? "(invalid)")
    self._color = State(
      initialValue: component?.extendedSrgbColor.extendedSRGBSwiftUIColor
        ?? Color(red: 1, green: 0, blue: 1))
  }

  var body: some View {
    Form {
      VideoComponentProgramLayers(storeService: storeService, componentID: videoComponentID)
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
    .disabled(storeService.isOutputActive || component == nil)
    .onChange(of: name) { updateComponent { $0.displayName = name } }
    .onChange(of: color) {
      guard let value = Ldtx_Workspace_V4_Color(extendedSRGBSwiftUIColor: color) else { return }
      updateComponent { $0.extendedSrgbColor = value }
    }
  }

  private func updateComponent(
    _ mutation: (inout Ldtx_Workspace_V4_FillSolidColorComponent) -> Void
  ) {
    guard !storeService.isOutputActive else { return }
    var definition = storeService.definition
    guard let index = definition.videoComponents.firstIndex(where: { $0.id == videoComponentID }),
      case .solidColorFill(var component) = definition.videoComponents[index].videoComponent
    else { return }
    mutation(&component)
    definition.videoComponents[index].videoComponent = .solidColorFill(component)
    storeService.definition = definition
  }

}

#if DEBUG
  #Preview("Default") {
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .solidColorFillVideoComponent, internalID: 4))
    SolidColorFillVideoComponentInspector(
      storeService: storeService, videoComponentID: .solidColorFill(4)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Output Active") {
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .solidColorFillVideoComponent, internalID: 4),
      isOutputActive: true)
    SolidColorFillVideoComponentInspector(
      storeService: storeService, videoComponentID: .solidColorFill(4)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Invalid") {
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .solidColorFillVideoComponent, internalID: 4))
    SolidColorFillVideoComponentInspector(
      storeService: storeService, videoComponentID: .solidColorFill(404)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }
#endif
