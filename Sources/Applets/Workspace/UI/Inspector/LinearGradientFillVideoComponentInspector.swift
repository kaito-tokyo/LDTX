// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

struct LinearGradientFillVideoComponentInspector: View {
  let storeService: WorkspaceStoreService
  let videoComponentID: WorkspaceStoreService.VideoComponentWrapper.ID

  private let component: Ldtx_Workspace_V4_FillLinearGradientComponent?

  @State private var name: String
  @State private var startX: Float
  @State private var startY: Float
  @State private var endX: Float
  @State private var endY: Float
  @State private var startColor: Color
  @State private var endColor: Color

  init(
    storeService: WorkspaceStoreService,
    videoComponentID: WorkspaceStoreService.VideoComponentWrapper.ID
  ) {
    self.storeService = storeService
    self.videoComponentID = videoComponentID
    self.component = storeService.definition.videoComponents
      .first(where: { $0.id == videoComponentID })
      .flatMap { wrapper in
        guard case .linearGradientFill(let component) = wrapper.definition else { return nil }
        return component
      }
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
      VideoComponentProgramLayers(storeService: storeService, componentID: videoComponentID)
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
    .disabled(storeService.isOutputActive || component == nil)
    .onChange(of: name) { commitDraft() }
    .onChange(of: startX) { commitDraft() }
    .onChange(of: startY) { commitDraft() }
    .onChange(of: endX) { commitDraft() }
    .onChange(of: endY) { commitDraft() }
    .onChange(of: startColor) { commitDraft() }
    .onChange(of: endColor) { commitDraft() }
    .onSubmit { commitDraft() }
  }

  private func commitDraft() {
    guard
      var component,
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

    var definition = storeService.definition
    guard let index = definition.videoComponents.firstIndex(where: { $0.id == videoComponentID })
    else { return }
    definition.videoComponents[index].definition = .linearGradientFill(component)
    storeService.definition = definition
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
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .linearGradientFillVideoComponent, internalID: 5))
    LinearGradientFillVideoComponentInspector(
      storeService: storeService, videoComponentID: .linearGradientFill(5)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Output Active") {
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .linearGradientFillVideoComponent, internalID: 5),
      isOutputActive: true)
    LinearGradientFillVideoComponentInspector(
      storeService: storeService, videoComponentID: .linearGradientFill(5)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Invalid") {
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .linearGradientFillVideoComponent, internalID: 5))
    LinearGradientFillVideoComponentInspector(
      storeService: storeService, videoComponentID: .linearGradientFill(404)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }
#endif
