// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
import SwiftUI

struct SolidColorFillVideoComponentInspector: View {
  @Environment(\.undoManager) private var undoManager
  let stateService: WorkspaceDocument
  let appletData: WorkspaceAppletData
  let videoComponentID: Int64

  init(
    stateService: WorkspaceDocument,
    appletData: WorkspaceAppletData,
    videoComponentID: Int64
  ) {
    self.stateService = stateService
    self.appletData = appletData
    self.videoComponentID = videoComponentID
  }

  private var component: Ldtx_Workspace_V4_FillSolidColorComponent? {
    stateService.workspaceDefinition.videoComponents
      .first(where: { $0.internalID == videoComponentID })
      .flatMap { wrapper in
        guard case .solidColorFill(let component) = wrapper.videoComponent else { return nil }
        return component
      }
  }

  private var color: Color {
    component.flatMap { ($0.extendedSrgbColor ?? .init()).extendedSRGBSwiftUIColor }
      ?? Color(red: 1, green: 0, blue: 1)
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

        TextField(
          "Name",
          text: componentBinding(\.displayName, initial: "(invalid)", undoManager: undoManager))

        ColorPicker(
          "Color",
          selection: colorBinding(\.extendedSrgbColor, initial: color, undoManager: undoManager),
          supportsOpacity: true)
      }
      VideoComponentDeleteButton(stateService: stateService, componentID: videoComponentID)
    }
    .formStyle(.grouped)
    .disabled(stateService.isOutputActive || component == nil)
  }

  func componentBinding<Value>(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_FillSolidColorComponent, Value?>,
    initial: Value, undoManager: UndoManager?
  ) -> Binding<Value> {
    Binding(
      get: { component?[keyPath: keyPath] ?? initial },
      set: { next in
        updateComponent(undoManager: undoManager) { $0[keyPath: keyPath] = next }
      })
  }

  func colorBinding(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_FillSolidColorComponent, Ldtx_Workspace_V4_Color?>,
    initial: Color, undoManager: UndoManager?
  ) -> Binding<Color> {
    Binding(
      get: {
        component.flatMap { ($0[keyPath: keyPath] ?? .init()).extendedSRGBSwiftUIColor } ?? initial
      },
      set: { next in
        guard let value = Ldtx_Workspace_V4_Color(extendedSRGBSwiftUIColor: next) else { return }
        updateComponent(undoManager: undoManager) { $0[keyPath: keyPath] = value }
      })
  }

  private func updateComponent(
    undoManager: UndoManager?, _ mutation: (inout Ldtx_Workspace_V4_FillSolidColorComponent) -> Void
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
    stateService.editWorkspace(undoManager: undoManager) { workspace in
      workspace.definition = definition
    }
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
