// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import LDTXProtosMacOSExtra
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
        guard case .conicGradientFill(let component) = wrapper.videoComponent else { return nil }
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
    self._startAngleRadians = State(
      initialValue: component?.startAngleRadians
        ?? .with {
          $0.set(num: 0, den: 1)
        })
    self._startColor = State(
      initialValue: component?.startExtendedSrgbColor.extendedSRGBSwiftUIColor ?? .black)
    self._endColor = State(
      initialValue: component?.endExtendedSrgbColor.extendedSRGBSwiftUIColor ?? .white)
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
          Slider(value: $centerX.sliderValue(denominator: 1_000_000), in: 0...1)
        }
        LabeledContent("Center Y") {
          Slider(value: $centerY.sliderValue(denominator: 1_000_000), in: 0...1)
        }
        LabeledContent("Start Angle") {
          Slider(
            value: $startAngleRadians.sliderValue(denominator: 1_000_000), in: 0...(Double.pi * 2))
        }
        ColorPicker("Start Color", selection: $startColor, supportsOpacity: true)
        ColorPicker("End Color", selection: $endColor, supportsOpacity: true)
      }
    }
    .formStyle(.grouped)
    .disabled(storeService.isOutputActive || component == nil)
    .onChange(of: name) { updateComponent { $0.displayName = name } }
    .onChange(of: centerX) { updateComponent { $0.centerX = centerX } }
    .onChange(of: centerY) { updateComponent { $0.centerY = centerY } }
    .onChange(of: startAngleRadians) {
      updateComponent { $0.startAngleRadians = startAngleRadians }
    }
    .onChange(of: startColor) {
      guard let value = Ldtx_Workspace_V4_Color(extendedSRGBSwiftUIColor: startColor) else {
        return
      }
      updateComponent { $0.startExtendedSrgbColor = value }
    }
    .onChange(of: endColor) {
      guard let value = Ldtx_Workspace_V4_Color(extendedSRGBSwiftUIColor: endColor) else { return }
      updateComponent { $0.endExtendedSrgbColor = value }
    }
  }

  private func updateComponent(
    _ mutation: (inout Ldtx_Workspace_V4_FillConicGradientComponent) -> Void
  ) {
    guard !storeService.isOutputActive else { return }
    var definition = storeService.definition
    guard let index = definition.videoComponents.firstIndex(where: { $0.id == videoComponentID }),
      case .conicGradientFill(var component) = definition.videoComponents[index].videoComponent
    else { return }
    mutation(&component)
    definition.videoComponents[index].videoComponent = .conicGradientFill(component)
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
