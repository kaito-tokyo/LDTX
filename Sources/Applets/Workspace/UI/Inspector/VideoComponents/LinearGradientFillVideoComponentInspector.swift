// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProtos
import LDTXProtosMacOSExtra
import SwiftUI

struct LinearGradientFillVideoComponentInspector: View {
  let storeService: WorkspaceStoreService
  let videoComponentID: WorkspaceStoreService.VideoComponentWrapper.ID

  private let component: Ldtx_Workspace_V4_FillLinearGradientComponent?

  @State private var name: String
  @State private var startX: Ldtx_Workspace_V4_Rational32
  @State private var startY: Ldtx_Workspace_V4_Rational32
  @State private var endX: Ldtx_Workspace_V4_Rational32
  @State private var endY: Ldtx_Workspace_V4_Rational32
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
        guard case .linearGradientFill(let component) = wrapper.videoComponent else { return nil }
        return component
      }
    self._name = State(initialValue: component?.displayName ?? "(invalid)")
    self._startX = State(
      initialValue: component?.startX
        ?? .with {
          $0.set(num: 0, den: 1)
        })
    self._startY = State(
      initialValue: component?.startY
        ?? .with {
          $0.set(num: 0, den: 1)
        })
    self._endX = State(
      initialValue: component?.endX
        ?? .with {
          $0.set(num: 1, den: 1)
        })
    self._endY = State(
      initialValue: component?.endY
        ?? .with {
          $0.set(num: 1, den: 1)
        })
    self._startColor = State(
      initialValue: component?.startExtendedSrgbColor.extendedSRGBSwiftUIColor ?? .black)
    self._endColor = State(
      initialValue: component?.endExtendedSrgbColor.extendedSRGBSwiftUIColor ?? .black)
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
          Slider(value: $startX.sliderValue(denominator: 1_000_000), in: 0...1)
        }
        LabeledContent("Start Y") {
          Slider(value: $startY.sliderValue(denominator: 1_000_000), in: 0...1)
        }
        LabeledContent("End X") {
          Slider(value: $endX.sliderValue(denominator: 1_000_000), in: 0...1)
        }
        LabeledContent("End Y") {
          Slider(value: $endY.sliderValue(denominator: 1_000_000), in: 0...1)
        }
        ColorPicker("Start Color", selection: $startColor, supportsOpacity: true)
        ColorPicker("End Color", selection: $endColor, supportsOpacity: true)
      }
    }
    .formStyle(.grouped)
    .disabled(storeService.isOutputActive || component == nil)
    .onChange(of: name) { updateComponent { $0.displayName = name } }
    .onChange(of: startX) { updateComponent { $0.startX = startX } }
    .onChange(of: startY) { updateComponent { $0.startY = startY } }
    .onChange(of: endX) { updateComponent { $0.endX = endX } }
    .onChange(of: endY) { updateComponent { $0.endY = endY } }
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
    _ mutation: (inout Ldtx_Workspace_V4_FillLinearGradientComponent) -> Void
  ) {
    guard !storeService.isOutputActive else { return }
    var definition = storeService.definition
    guard let index = definition.videoComponents.firstIndex(where: { $0.id == videoComponentID }),
      case .linearGradientFill(var component) = definition.videoComponents[index].videoComponent
    else { return }
    mutation(&component)
    definition.videoComponents[index].videoComponent = .linearGradientFill(component)
    storeService.definition = definition
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
