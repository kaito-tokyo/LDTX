// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import SwiftUI

struct RadialGradientFillVideoComponentInspector: View {
  let storeService: WorkspaceStoreService
  let videoComponentID: WorkspaceStoreService.VideoComponentWrapper.ID

  private let component: Ldtx_Workspace_V4_FillRadialGradientComponent?

  @State private var name: String
  @State private var centerX: Ldtx_Workspace_V4_Rational32
  @State private var centerY: Ldtx_Workspace_V4_Rational32
  @State private var innerRadius: Ldtx_Workspace_V4_Rational32
  @State private var outerRadius: Ldtx_Workspace_V4_Rational32
  @State private var innerColor: Color
  @State private var outerColor: Color

  init(
    storeService: WorkspaceStoreService,
    videoComponentID: WorkspaceStoreService.VideoComponentWrapper.ID
  ) {
    self.storeService = storeService
    self.videoComponentID = videoComponentID
    self.component = storeService.definition.videoComponents
      .first(where: { $0.id == videoComponentID })
      .flatMap { wrapper in
        guard case .radialGradientFill(let component) = wrapper.definition else { return nil }
        return component
      }
    self._name = State(initialValue: component?.displayName ?? "(invalid)")
    self._centerX = State(
      initialValue: component?.centerXRational
        ?? .with {
          $0.set(num: 1, den: 2)
        })
    self._centerY = State(
      initialValue: component?.centerYRational
        ?? .with {
          $0.set(num: 1, den: 2)
        })
    self._innerRadius = State(
      initialValue: component?.innerRadiusRational
        ?? .with {
          $0.set(num: 0, den: 1)
        })
    self._outerRadius = State(
      initialValue: component?.outerRadiusRational
        ?? .with {
          $0.set(num: 18, den: 25)
        })
    self._innerColor = State(initialValue: component?.innerColor.asColor() ?? .white)
    self._outerColor = State(initialValue: component?.outerColor.asColor() ?? .black)
  }

  var body: some View {
    Form {
      VideoComponentProgramLayers(storeService: storeService, componentID: videoComponentID)
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
          Slider(value: $centerX.double, in: 0...1)
        }
        LabeledContent("Center Y") {
          Slider(value: $centerY.double, in: 0...1)
        }
        LabeledContent("Inner Radius") {
          Slider(value: $innerRadius.double, in: 0...1)
        }
        LabeledContent("Outer Radius") {
          Slider(value: $outerRadius.double, in: 0...1)
        }
        ColorPicker("Inner Color", selection: $innerColor, supportsOpacity: true)
        ColorPicker("Outer Color", selection: $outerColor, supportsOpacity: true)
      }
    }
    .formStyle(.grouped)
    .disabled(storeService.isOutputActive || component == nil)
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
    component.centerXRational = centerX
    component.centerYRational = centerY
    component.innerRadiusRational = innerRadius
    component.outerRadiusRational = outerRadius
    component.innerColor.red = Float(innerNSColor.redComponent)
    component.innerColor.green = Float(innerNSColor.greenComponent)
    component.innerColor.blue = Float(innerNSColor.blueComponent)
    component.innerColor.alpha = Float(innerNSColor.alphaComponent)
    component.outerColor.red = Float(outerNSColor.redComponent)
    component.outerColor.green = Float(outerNSColor.greenComponent)
    component.outerColor.blue = Float(outerNSColor.blueComponent)
    component.outerColor.alpha = Float(outerNSColor.alphaComponent)

    var definition = storeService.definition
    guard let index = definition.videoComponents.firstIndex(where: { $0.id == videoComponentID })
    else { return }
    definition.videoComponents[index].definition = .radialGradientFill(component)
    storeService.definition = definition
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
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .radialGradientFillVideoComponent, internalID: 6))
    RadialGradientFillVideoComponentInspector(
      storeService: storeService, videoComponentID: .radialGradientFill(6)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Output Active") {
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .radialGradientFillVideoComponent, internalID: 6),
      isOutputActive: true)
    RadialGradientFillVideoComponentInspector(
      storeService: storeService, videoComponentID: .radialGradientFill(6)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Invalid") {
    @Previewable @State var storeService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .radialGradientFillVideoComponent, internalID: 6))
    RadialGradientFillVideoComponentInspector(
      storeService: storeService, videoComponentID: .radialGradientFill(404)
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }
#endif
