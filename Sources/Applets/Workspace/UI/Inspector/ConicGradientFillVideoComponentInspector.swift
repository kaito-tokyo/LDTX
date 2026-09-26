// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

struct ConicGradientFillVideoComponentInspector: View {
  let uiState: WorkspaceUIState
  let videoComponentID: WorkspaceUIState.VideoComponentWrapper.ID

  private let component: Ldtx_Workspace_V4_FillConicGradientComponent?

  @State private var name: String
  @State private var centerX: Float
  @State private var centerY: Float
  @State private var startAngleRadians: Float
  @State private var startColor: Color
  @State private var endColor: Color

  init(uiState: WorkspaceUIState, videoComponentID: WorkspaceUIState.VideoComponentWrapper.ID) {
    self.uiState = uiState
    self.videoComponentID = videoComponentID
    self.component = uiState.findVideoComponent(id: videoComponentID)
    self._name = State(initialValue: component?.displayName ?? "(invalid)")
    self._centerX = State(initialValue: component?.centerX ?? 0.5)
    self._centerY = State(initialValue: component?.centerY ?? 0.5)
    self._startAngleRadians = State(initialValue: component?.startAngleRadians ?? 0)
    self._startColor = State(initialValue: component?.startColor.asColor() ?? .black)
    self._endColor = State(initialValue: component?.endColor.asColor() ?? .white)
  }

  var body: some View {
    Form {
      Section("Conic Gradient Fill") {
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
        LabeledContent("Start Angle") {
          Slider(value: $startAngleRadians, in: 0...(Float.pi * 2))
        }
        ColorPicker("Start Color", selection: $startColor, supportsOpacity: true)
        ColorPicker("End Color", selection: $endColor, supportsOpacity: true)
      }
    }
    .formStyle(.grouped)
    .disabled(uiState.isOutputActive || component == nil)
    .onSubmit {
      guard
        var component = self.component,
        let startNSColor = NSColor(startColor).usingColorSpace(.sRGB),
        let endNSColor = NSColor(endColor).usingColorSpace(.sRGB)
      else { return }

      component.displayName = name
      component.centerX = centerX
      component.centerY = centerY
      component.startAngleRadians = startAngleRadians
      component.startColor.red = Float(startNSColor.redComponent)
      component.startColor.green = Float(startNSColor.greenComponent)
      component.startColor.blue = Float(startNSColor.blueComponent)
      component.startColor.alpha = Float(startNSColor.alphaComponent)
      component.endColor.red = Float(endNSColor.redComponent)
      component.endColor.green = Float(endNSColor.greenComponent)
      component.endColor.blue = Float(endNSColor.blueComponent)
      component.endColor.alpha = Float(endNSColor.alphaComponent)

      uiState.replaceVideoComponent(
        id: videoComponentID,
        with: .conicGradientFill(component))
    }
  }

  private var gradient: AngularGradient {
    AngularGradient(
      colors: [startColor, endColor],
      center: UnitPoint(x: Double(centerX), y: Double(centerY)),
      startAngle: .radians(Double(startAngleRadians)),
      endAngle: .radians(Double(startAngleRadians) + 2 * .pi))
  }
}

#if DEBUG
  #Preview("Default") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorKind: .conicGradientFillVideoComponent(7))
    ConicGradientFillVideoComponentInspector(
      uiState: uiState, videoComponentID: .conicGradientFill(7))
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Output Active") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorKind: .conicGradientFillVideoComponent(7), isOutputActive: true)
    ConicGradientFillVideoComponentInspector(
      uiState: uiState, videoComponentID: .conicGradientFill(7))
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }
#endif
