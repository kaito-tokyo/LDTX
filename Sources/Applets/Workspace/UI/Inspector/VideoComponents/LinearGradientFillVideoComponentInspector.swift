// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import LDTXProtosMacOSExtra
import SwiftUI

struct LinearGradientFillVideoComponentInspector: View {
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

  private var component: Ldtx_Workspace_V4_FillLinearGradientComponent? {
    stateService.workspaceDefinition.videoComponents
      .first(where: { $0.internalID == videoComponentID })
      .flatMap { wrapper in
        guard case .linearGradientFill(let component) = wrapper.videoComponent else { return nil }
        return component
      }
  }

  private var startX: Ldtx_Workspace_V4_Rational32 {
    component?.startX
      ?? .with {
        $0.set(num: 0, den: 1)
      }
  }

  private var startY: Ldtx_Workspace_V4_Rational32 {
    component?.startY
      ?? .with {
        $0.set(num: 0, den: 1)
      }
  }

  private var endX: Ldtx_Workspace_V4_Rational32 {
    component?.endX
      ?? .with {
        $0.set(num: 1, den: 1)
      }
  }

  private var endY: Ldtx_Workspace_V4_Rational32 {
    component?.endY
      ?? .with {
        $0.set(num: 1, den: 1)
      }
  }

  private var startColor: Color {
    component?.startExtendedSrgbColor.extendedSRGBSwiftUIColor ?? .black
  }

  private var endColor: Color {
    component?.endExtendedSrgbColor.extendedSRGBSwiftUIColor ?? .black
  }

  var body: some View {
    Form {
      VideoComponentProgramLayers(
        stateService: stateService, appletData: appletData, componentID: videoComponentID)
      Section("Linear Gradient Fill") {
        HStack(alignment: .center, spacing: 4) {
          Rectangle()
            .fill(gradient)
            .aspectRatio(16 / 9, contentMode: .fit)
          Rectangle()
            .fill(gradient)
            .aspectRatio(9 / 16, contentMode: .fit)
        }
        .aspectRatio(16 / 9 + 9 / 16, contentMode: .fit)

        TextField(
          "Name",
          text: componentBinding(\.displayName, initial: "(invalid)", undoManager: undoManager))
        LabeledContent("Start X") {
          Slider(
            value: componentBinding(\.startX, initial: startX, undoManager: undoManager)
              .sliderValue(denominator: 1_000_000), in: 0...1)
        }
        LabeledContent("Start Y") {
          Slider(
            value: componentBinding(\.startY, initial: startY, undoManager: undoManager)
              .sliderValue(denominator: 1_000_000), in: 0...1)
        }
        LabeledContent("End X") {
          Slider(
            value: componentBinding(\.endX, initial: endX, undoManager: undoManager).sliderValue(
              denominator: 1_000_000), in: 0...1)
        }
        LabeledContent("End Y") {
          Slider(
            value: componentBinding(\.endY, initial: endY, undoManager: undoManager).sliderValue(
              denominator: 1_000_000), in: 0...1)
        }
        ColorPicker(
          "Start Color",
          selection: colorBinding(
            \.startExtendedSrgbColor, initial: startColor, undoManager: undoManager),
          supportsOpacity: true)
        ColorPicker(
          "End Color",
          selection: colorBinding(
            \.endExtendedSrgbColor, initial: endColor, undoManager: undoManager),
          supportsOpacity: true)
      }
      VideoComponentDeleteButton(stateService: stateService, componentID: videoComponentID)
    }
    .formStyle(.grouped)
    .disabled(stateService.isOutputActive || component == nil)
  }

  func componentBinding<Value>(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_FillLinearGradientComponent, Value>,
    initial: Value, undoManager: UndoManager?
  ) -> Binding<Value> {
    Binding(
      get: { component?[keyPath: keyPath] ?? initial },
      set: { next in
        updateComponent(undoManager: undoManager) { $0[keyPath: keyPath] = next }
      })
  }

  func colorBinding(
    _ keyPath: WritableKeyPath<
      Ldtx_Workspace_V4_FillLinearGradientComponent, Ldtx_Workspace_V4_Color
    >,
    initial: Color, undoManager: UndoManager?
  ) -> Binding<Color> {
    Binding(
      get: { component?[keyPath: keyPath].extendedSRGBSwiftUIColor ?? initial },
      set: { next in
        guard let value = Ldtx_Workspace_V4_Color(extendedSRGBSwiftUIColor: next) else { return }
        updateComponent(undoManager: undoManager) { $0[keyPath: keyPath] = value }
      })
  }

  private func updateComponent(
    undoManager: UndoManager?,
    _ mutation: (inout Ldtx_Workspace_V4_FillLinearGradientComponent) -> Void
  ) {
    guard !stateService.isOutputActive else { return }
    var definition = stateService.workspaceDefinition
    guard
      let index = definition.videoComponents.firstIndex(where: { $0.internalID == videoComponentID }
      ),
      case .linearGradientFill(var component) = definition.videoComponents[index].videoComponent
    else { return }
    mutation(&component)
    definition.videoComponents[index].videoComponent = .linearGradientFill(component)
    stateService.editWorkspace(undoManager: undoManager) { workspace in
      workspace.definition = definition
    }
  }

  private var gradient: LinearGradient {
    LinearGradient(
      colors: [startColor, endColor],
      startPoint: UnitPoint(x: startX.double, y: startY.double),
      endPoint: UnitPoint(x: endX.double, y: endY.double))
  }
}

#if DEBUG
  #Preview("Default") {
    @Previewable @State var stateService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .linearGradientFillVideoComponent, internalID: 5))
    LinearGradientFillVideoComponentInspector(
      stateService: stateService, appletData: WorkspaceAppletData(), videoComponentID: 5
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Output Active") {
    @Previewable @State var stateService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .linearGradientFillVideoComponent, internalID: 5),
      isOutputActive: true)
    LinearGradientFillVideoComponentInspector(
      stateService: stateService, appletData: WorkspaceAppletData(), videoComponentID: 5
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Invalid") {
    @Previewable @State var stateService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .linearGradientFillVideoComponent, internalID: 5))
    LinearGradientFillVideoComponentInspector(
      stateService: stateService, appletData: WorkspaceAppletData(), videoComponentID: 404
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }
#endif
