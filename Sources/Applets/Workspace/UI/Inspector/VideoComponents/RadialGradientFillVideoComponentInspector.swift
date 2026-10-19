// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import LDTXProtosMacOSExtra
import SwiftUI

struct RadialGradientFillVideoComponentInspector: View {
  @Environment(\.undoManager) private var undoManager
  let stateService: WorkspaceDocument
  let appletData: WorkspaceAppletData
  let videoComponentID: Int64

  private let component: Ldtx_Workspace_V4_FillRadialGradientComponent?

  @State private var name: String
  @State private var centerX: Ldtx_Workspace_V4_Rational32
  @State private var centerY: Ldtx_Workspace_V4_Rational32
  @State private var innerRadius: Ldtx_Workspace_V4_Rational32
  @State private var outerRadius: Ldtx_Workspace_V4_Rational32
  @State private var innerColor: Color
  @State private var outerColor: Color

  init(
    stateService: WorkspaceDocument,
    appletData: WorkspaceAppletData,
    videoComponentID: Int64
  ) {
    self.stateService = stateService
    self.appletData = appletData
    self.videoComponentID = videoComponentID
    self.component = stateService.workspaceDefinition.videoComponents
      .first(where: { $0.internalID == videoComponentID })
      .flatMap { wrapper in
        guard case .radialGradientFill(let component) = wrapper.videoComponent else { return nil }
        return component
      }
    self._name = State(initialValue: component?.displayName ?? "(invalid)")
    self._centerX = State(
      initialValue: component?.centerX
        ?? .with {
          $0.set(num: 1, den: 2)
        })
    self._centerY = State(
      initialValue: component?.centerY
        ?? .with {
          $0.set(num: 1, den: 2)
        })
    self._innerRadius = State(
      initialValue: component?.innerRadius
        ?? .with {
          $0.set(num: 0, den: 1)
        })
    self._outerRadius = State(
      initialValue: component?.outerRadius
        ?? .with {
          $0.set(num: 18, den: 25)
        })
    self._innerColor = State(
      initialValue: component?.innerExtendedSrgbColor.extendedSRGBSwiftUIColor ?? .white)
    self._outerColor = State(
      initialValue: component?.outerExtendedSrgbColor.extendedSRGBSwiftUIColor ?? .black)
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

        TextField("Name", text: $name)
        LabeledContent("Center X") {
          Slider(value: $centerX.sliderValue(denominator: 1_000_000), in: 0...1)
        }
        LabeledContent("Center Y") {
          Slider(value: $centerY.sliderValue(denominator: 1_000_000), in: 0...1)
        }
        LabeledContent("Inner Radius") {
          Slider(value: $innerRadius.sliderValue(denominator: 1_000_000), in: 0...1)
        }
        LabeledContent("Outer Radius") {
          Slider(value: $outerRadius.sliderValue(denominator: 1_000_000), in: 0...1)
        }
        ColorPicker("Inner Color", selection: $innerColor, supportsOpacity: true)
        ColorPicker("Outer Color", selection: $outerColor, supportsOpacity: true)
      }
      VideoComponentDeleteButton(stateService: stateService, componentID: videoComponentID)
    }
    .formStyle(.grouped)
    .disabled(stateService.isOutputActive || component == nil)
    .onChange(of: name) { updateComponent { $0.displayName = name } }
    .onChange(of: centerX) { updateComponent { $0.centerX = centerX } }
    .onChange(of: centerY) { updateComponent { $0.centerY = centerY } }
    .onChange(of: innerRadius) { updateComponent { $0.innerRadius = innerRadius } }
    .onChange(of: outerRadius) { updateComponent { $0.outerRadius = outerRadius } }
    .onChange(of: innerColor) {
      guard let value = Ldtx_Workspace_V4_Color(extendedSRGBSwiftUIColor: innerColor) else {
        return
      }
      updateComponent { $0.innerExtendedSrgbColor = value }
    }
    .onChange(of: outerColor) {
      guard let value = Ldtx_Workspace_V4_Color(extendedSRGBSwiftUIColor: outerColor) else {
        return
      }
      updateComponent { $0.outerExtendedSrgbColor = value }
    }
  }

  private func updateComponent(
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
