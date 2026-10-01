// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

struct RadialGradientFillVideoComponentInspector: View {
  let uiState: WorkspaceUIState
  let videoComponentID: WorkspaceUIState.VideoComponentWrapper.ID

  private let component: Ldtx_Workspace_V4_FillRadialGradientComponent?

  @State private var name: String
  @State private var centerX: Float
  @State private var centerY: Float
  @State private var innerRadius: Float
  @State private var outerRadius: Float
  @State private var innerColor: Color
  @State private var outerColor: Color

  init(uiState: WorkspaceUIState, videoComponentID: WorkspaceUIState.VideoComponentWrapper.ID) {
    self.uiState = uiState
    self.videoComponentID = videoComponentID
    self.component = uiState.definition.videoComponents
      .first(where: { $0.id == videoComponentID })
      .flatMap { wrapper in
        guard case .radialGradientFill(let component) = wrapper.definition else { return nil }
        return component
      }
    self._name = State(initialValue: component?.displayName ?? "(invalid)")
    self._centerX = State(initialValue: component?.centerX ?? 0.5)
    self._centerY = State(initialValue: component?.centerY ?? 0.5)
    self._innerRadius = State(initialValue: component?.innerRadius ?? 0)
    self._outerRadius = State(initialValue: component?.outerRadius ?? 0.72)
    self._innerColor = State(initialValue: component?.innerColor.asColor() ?? .white)
    self._outerColor = State(initialValue: component?.outerColor.asColor() ?? .black)
  }

  var body: some View {
    Form {
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
          Slider(value: $centerX, in: 0...1)
        }
        LabeledContent("Center Y") {
          Slider(value: $centerY, in: 0...1)
        }
        LabeledContent("Inner Radius") {
          Slider(value: $innerRadius, in: 0...1)
        }
        LabeledContent("Outer Radius") {
          Slider(value: $outerRadius, in: 0...1)
        }
        ColorPicker("Inner Color", selection: $innerColor, supportsOpacity: true)
        ColorPicker("Outer Color", selection: $outerColor, supportsOpacity: true)
      }
    }
    .formStyle(.grouped)
    .disabled(uiState.isOutputActive || component == nil)
    .onChange(of: name) { commitDraft() }
    .onChange(of: centerX) { commitDraft() }
    .onChange(of: centerY) { commitDraft() }
    .onChange(of: innerRadius) { commitDraft() }
    .onChange(of: outerRadius) { commitDraft() }
    .onChange(of: innerColor) { commitDraft() }
    .onChange(of: outerColor) { commitDraft() }
    .onSubmit { commitDraft() }
  }

  private func commitDraft() {
    guard
      var component,
      let innerNSColor = NSColor(innerColor).usingColorSpace(.sRGB),
      let outerNSColor = NSColor(outerColor).usingColorSpace(.sRGB)
    else { return }

    component.displayName = name
    component.centerX = centerX
    component.centerY = centerY
    component.innerRadius = innerRadius
    component.outerRadius = outerRadius
    component.innerColor.red = Float(innerNSColor.redComponent)
    component.innerColor.green = Float(innerNSColor.greenComponent)
    component.innerColor.blue = Float(innerNSColor.blueComponent)
    component.innerColor.alpha = Float(innerNSColor.alphaComponent)
    component.outerColor.red = Float(outerNSColor.redComponent)
    component.outerColor.green = Float(outerNSColor.greenComponent)
    component.outerColor.blue = Float(outerNSColor.blueComponent)
    component.outerColor.alpha = Float(outerNSColor.alphaComponent)

    var definition = uiState.definition
    guard let index = definition.videoComponents.firstIndex(where: { $0.id == videoComponentID })
    else { return }
    definition.videoComponents[index].definition = .radialGradientFill(component)
    uiState.definition = definition
    uiState.recordDefinitionChange()
  }

  private var gradient: RadialGradient {
    RadialGradient(
      colors: [innerColor, outerColor],
      center: UnitPoint(x: Double(centerX), y: Double(centerY)),
      startRadius: CGFloat(innerRadius) * 96,
      endRadius: CGFloat(outerRadius) * 96)
  }
}

#if DEBUG
  #Preview("Default") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .radialGradientFillVideoComponent, internalID: 6))
    RadialGradientFillVideoComponentInspector(
      uiState: uiState, videoComponentID: .radialGradientFill(6)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Output Active") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .radialGradientFillVideoComponent, internalID: 6),
      isOutputActive: true)
    RadialGradientFillVideoComponentInspector(
      uiState: uiState, videoComponentID: .radialGradientFill(6)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Invalid") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .radialGradientFillVideoComponent, internalID: 6))
    RadialGradientFillVideoComponentInspector(
      uiState: uiState, videoComponentID: .radialGradientFill(404)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }
#endif
