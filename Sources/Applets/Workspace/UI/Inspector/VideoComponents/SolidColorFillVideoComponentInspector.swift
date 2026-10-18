// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import LDTXProtosMacOSExtra
import SwiftUI

struct SolidColorFillVideoComponentInspector: View {
  let stateService: WorkspaceStateService
  let appletData: WorkspaceAppletData
  let videoComponentID: Int64

  private let component: Ldtx_Workspace_V4_FillSolidColorComponent?

  @State private var name: String
  @State private var color: Color

  init(
    stateService: WorkspaceStateService,
    appletData: WorkspaceAppletData,
    videoComponentID: Int64
  ) {
    self.stateService = stateService
    self.appletData = appletData
    self.videoComponentID = videoComponentID
    self.component = stateService.workspaceDefinition.videoComponents
      .first(where: { $0.internalID == videoComponentID })
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
      VideoComponentProgramLayers(
        stateService: stateService, appletData: appletData, componentID: videoComponentID)
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
      VideoComponentDeleteButton(stateService: stateService, componentID: videoComponentID)
    }
    .formStyle(.grouped)
    .disabled(stateService.isOutputActive || component == nil)
    .onChange(of: name) { updateComponent { $0.displayName = name } }
    .onChange(of: color) {
      guard let value = Ldtx_Workspace_V4_Color(extendedSRGBSwiftUIColor: color) else { return }
      updateComponent { $0.extendedSrgbColor = value }
    }
  }

  private func updateComponent(
    _ mutation: (inout Ldtx_Workspace_V4_FillSolidColorComponent) -> Void
  ) {
    guard !stateService.isOutputActive else { return }
    var definition = stateService.workspaceDefinition
    guard
      let index = definition.videoComponents.firstIndex(where: { $0.internalID == videoComponentID }
      ),
      case .solidColorFill(var component) = definition.videoComponents[index].videoComponent
    else { return }
    mutation(&component)
    definition.videoComponents[index].videoComponent = .solidColorFill(component)
    stateService.workspaceDefinition = definition
  }

}

#if DEBUG
  #Preview("Default") {
    @Previewable @State var stateService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .solidColorFillVideoComponent, internalID: 4))
    SolidColorFillVideoComponentInspector(
      stateService: stateService, appletData: WorkspaceAppletData(), videoComponentID: 4
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Output Active") {
    @Previewable @State var stateService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .solidColorFillVideoComponent, internalID: 4),
      isOutputActive: true)
    SolidColorFillVideoComponentInspector(
      stateService: stateService, appletData: WorkspaceAppletData(), videoComponentID: 4
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Invalid") {
    @Previewable @State var stateService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .solidColorFillVideoComponent, internalID: 4))
    SolidColorFillVideoComponentInspector(
      stateService: stateService, appletData: WorkspaceAppletData(), videoComponentID: 404
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }
#endif
