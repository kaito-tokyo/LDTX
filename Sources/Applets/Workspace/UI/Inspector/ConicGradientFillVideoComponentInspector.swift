// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

struct ConicGradientFillVideoComponentInspector: View {
  let storeService: WorkspaceStoreService
  let videoComponentID: WorkspaceStoreService.VideoComponentWrapper.ID

  private let component: Ldtx_Workspace_V4_FillConicGradientComponent?

  @State private var name: String
  @State private var centerX: Ldtx_Workspace_V4_Rational32
  @State private var centerY: Ldtx_Workspace_V4_Rational32
  @State private var startAngleRadians: Ldtx_Workspace_V4_Rational32
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
        guard case .conicGradientFill(let component) = wrapper.definition else { return nil }
        return component
      }
    self._name = State(initialValue: component?.displayName ?? "(invalid)")
    self._centerX = State(
      initialValue: component?.centerXRational
        ?? .with {
          $0.numerator = 1
          $0.denominator = 2
        })
    self._centerY = State(
      initialValue: component?.centerYRational
        ?? .with {
          $0.numerator = 1
          $0.denominator = 2
        })
    self._startAngleRadians = State(
      initialValue: component?.startAngleRadiansRational
        ?? .with {
          $0.numerator = 0
          $0.denominator = 1
        })
    self._startColor = State(initialValue: component?.startColor.asColor() ?? .black)
    self._endColor = State(initialValue: component?.endColor.asColor() ?? .white)
  }

  var body: some View {
    Form {
      VideoComponentProgramLayers(storeService: storeService, componentID: videoComponentID)
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
          Slider(value: $centerX.double, in: 0...1)
        }
        LabeledContent("Center Y") {
          Slider(value: $centerY.double, in: 0...1)
        }
        LabeledContent("Start Angle") {
          Slider(value: $startAngleRadians.double, in: 0...(Double.pi * 2))
        }
        ColorPicker("Start Color", selection: $startColor, supportsOpacity: true)
        ColorPicker("End Color", selection: $endColor, supportsOpacity: true)
      }
    }
    .formStyle(.grouped)
    .disabled(storeService.isOutputActive || component == nil)
    .onChange(of: name) { commitDraft() }
    .onChange(of: centerX) { commitDraft() }
    .onChange(of: centerY) { commitDraft() }
    .onChange(of: startAngleRadians) { commitDraft() }
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
    component.centerXRational = centerX
    component.centerYRational = centerY
    component.startAngleRadiansRational = startAngleRadians
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
    definition.videoComponents[index].definition = .conicGradientFill(component)
    storeService.definition = definition
  }

  private var gradient: AngularGradient {
    AngularGradient(
      colors: [startColor, endColor],
      center: UnitPoint(x: centerX.double, y: centerY.double),
      startAngle: .radians(startAngleRadians.double),
      endAngle: .radians(startAngleRadians.double + 2 * .pi))
  }
}

#if DEBUG
  #Preview("Default") {
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .conicGradientFillVideoComponent, internalID: 7))
    ConicGradientFillVideoComponentInspector(
      storeService: storeService, videoComponentID: .conicGradientFill(7)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Output Active") {
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .conicGradientFillVideoComponent, internalID: 7),
      isOutputActive: true)
    ConicGradientFillVideoComponentInspector(
      storeService: storeService, videoComponentID: .conicGradientFill(7)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }
#endif
