// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import LDTXProtosMacOSExtra
import SwiftUI

struct RadialGradientFillVideoComponentInspector: View {
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

  private var component: Ldtx_Workspace_V4_FillRadialGradientComponent? {
    stateService.workspaceDefinition.videoComponents
      .first(where: { $0.internalID == videoComponentID })
      .flatMap { wrapper in
        guard case .radialGradientFill(let component) = wrapper.videoComponent else { return nil }
        return component
      }
  }

  private var centerX: Ldtx_Workspace_V4_Rational32 {
    component?.centerX
      ?? .with {
        $0.set(num: 1, den: 2)
      }
  }

  private var centerY: Ldtx_Workspace_V4_Rational32 {
    component?.centerY
      ?? .with {
        $0.set(num: 1, den: 2)
      }
  }

  private var innerRadius: Ldtx_Workspace_V4_Rational32 {
    component?.innerRadius
      ?? .with {
        $0.set(num: 0, den: 1)
      }
  }

  private var outerRadius: Ldtx_Workspace_V4_Rational32 {
    component?.outerRadius
      ?? .with {
        $0.set(num: 18, den: 25)
      }
  }

  private var innerColor: Color {
    component?.innerExtendedSrgbColor.extendedSRGBSwiftUIColor ?? .white
  }

  private var outerColor: Color {
    component?.outerExtendedSrgbColor.extendedSRGBSwiftUIColor ?? .black
  }

  var body: some View {
    Form {
      VideoComponentProgramLayers(
        stateService: stateService, appletData: appletData, componentID: videoComponentID)
      Section("Radial Gradient Fill") {
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
        LabeledContent("Center X") {
          Slider(
            value: componentBinding(\.centerX, initial: centerX, undoManager: undoManager)
              .sliderValue(denominator: 1_000_000), in: 0...1)
        }
        LabeledContent("Center Y") {
          Slider(
            value: componentBinding(\.centerY, initial: centerY, undoManager: undoManager)
              .sliderValue(denominator: 1_000_000), in: 0...1)
        }
        LabeledContent("Inner Radius") {
          Slider(
            value: componentBinding(\.innerRadius, initial: innerRadius, undoManager: undoManager)
              .sliderValue(denominator: 1_000_000), in: 0...1)
        }
        LabeledContent("Outer Radius") {
          Slider(
            value: componentBinding(\.outerRadius, initial: outerRadius, undoManager: undoManager)
              .sliderValue(denominator: 1_000_000), in: 0...1)
        }
        ColorPicker(
          "Inner Color",
          selection: colorBinding(
            \.innerExtendedSrgbColor, initial: innerColor, undoManager: undoManager),
          supportsOpacity: true)
        ColorPicker(
          "Outer Color",
          selection: colorBinding(
            \.outerExtendedSrgbColor, initial: outerColor, undoManager: undoManager),
          supportsOpacity: true)
      }
      VideoComponentDeleteButton(stateService: stateService, componentID: videoComponentID)
    }
    .formStyle(.grouped)
    .disabled(stateService.isOutputActive || component == nil)
  }

  func componentBinding<Value>(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_FillRadialGradientComponent, Value>,
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
      Ldtx_Workspace_V4_FillRadialGradientComponent, Ldtx_Workspace_V4_Color
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
    _ mutation: (inout Ldtx_Workspace_V4_FillRadialGradientComponent) -> Void
  ) {
    guard !stateService.isOutputActive else { return }
    var definition = stateService.workspaceDefinition
    guard
      let index = definition.videoComponents.firstIndex(where: { $0.internalID == videoComponentID }
      ),
      case .radialGradientFill(var component) = definition.videoComponents[index].videoComponent
    else { return }
    mutation(&component)
    definition.videoComponents[index].videoComponent = .radialGradientFill(component)
    stateService.editWorkspace(undoManager: undoManager) { workspace in
      workspace.definition = definition
    }
  }

  private var gradient: RadialGradient {
    RadialGradient(
      colors: [innerColor, outerColor],
      center: UnitPoint(x: centerX.double, y: centerY.double),
      startRadius: CGFloat(innerRadius.double) * 96,
      endRadius: CGFloat(outerRadius.double) * 96)
  }
}

#if DEBUG
  #Preview("Default") {
    @Previewable @State var stateService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .radialGradientFillVideoComponent, internalID: 6))
    RadialGradientFillVideoComponentInspector(
      stateService: stateService, appletData: WorkspaceAppletData(), videoComponentID: 6
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Output Active") {
    @Previewable @State var stateService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .radialGradientFillVideoComponent, internalID: 6),
      isOutputActive: true)
    RadialGradientFillVideoComponentInspector(
      stateService: stateService, appletData: WorkspaceAppletData(), videoComponentID: 6
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Invalid") {
    @Previewable @State var stateService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .radialGradientFillVideoComponent, internalID: 6))
    RadialGradientFillVideoComponentInspector(
      stateService: stateService, appletData: WorkspaceAppletData(), videoComponentID: 404
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }
#endif
