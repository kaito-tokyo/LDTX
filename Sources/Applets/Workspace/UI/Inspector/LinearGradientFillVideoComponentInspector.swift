// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

struct LinearGradientFillVideoComponentInspector: View {
  let uiState: WorkspaceUIState
  let videoComponentID: WorkspaceUIState.VideoComponentWrapper.ID

  private let component: Ldtx_Workspace_V4_FillLinearGradientComponent?

  @State private var name: String
  @State private var startX: Float
  @State private var startY: Float
  @State private var endX: Float
  @State private var endY: Float
  @State private var startColor: Color
  @State private var endColor: Color

  init(uiState: WorkspaceUIState, videoComponentID: WorkspaceUIState.VideoComponentWrapper.ID) {
    self.uiState = uiState
    self.videoComponentID = videoComponentID
    self.component = uiState.findVideoComponent(id: videoComponentID)
    self._name = State(initialValue: component?.displayName ?? "(invalid)")
    self._startX = State(initialValue: component?.startX ?? 0)
    self._startY = State(initialValue: component?.startY ?? 0)
    self._endX = State(initialValue: component?.endX ?? 1)
    self._endY = State(initialValue: component?.endY ?? 1)
    self._startColor = State(initialValue: component?.startColor.asColor() ?? .black)
    self._endColor = State(initialValue: component?.endColor.asColor() ?? .black)
  }

  var body: some View {
    Form {
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

        TextField("Name", text: $name)
        LabeledContent("Start X") {
          Slider(value: $startX, in: 0...1)
        }
        LabeledContent("Start Y") {
          Slider(value: $startY, in: 0...1)
        }
        LabeledContent("End X") {
          Slider(value: $endX, in: 0...1)
        }
        LabeledContent("End Y") {
          Slider(value: $endY, in: 0...1)
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
      component.startX = startX
      component.startY = startY
      component.endX = endX
      component.endY = endY
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
        with: .linearGradientFill(component))
    }
  }

  private var gradient: LinearGradient {
    LinearGradient(
      colors: [startColor, endColor],
      startPoint: UnitPoint(x: Double(startX), y: Double(startY)),
      endPoint: UnitPoint(x: Double(endX), y: Double(endY)))
  }
}

#if DEBUG
  #Preview("Default") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorKind: .linearGradientFillVideoComponent(5))
    LinearGradientFillVideoComponentInspector(
      uiState: uiState, videoComponentID: .linearGradientFill(5))
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Output Active") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorKind: .linearGradientFillVideoComponent(5), isOutputActive: true)
    LinearGradientFillVideoComponentInspector(
      uiState: uiState, videoComponentID: .linearGradientFill(5))
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Invalid") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorKind: .linearGradientFillVideoComponent(404))
    LinearGradientFillVideoComponentInspector(
      uiState: uiState, videoComponentID: .linearGradientFill(404))
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }
#endif
