// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
import LDTXProtosMacOSExtra
import SwiftUI

struct ConicGradientFillVideoComponentInspector: View {
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

  private var component: Ldtx_Workspace_V4_FillConicGradientComponent? {
    stateService.workspaceDefinition.videoComponents
      .first(where: { $0.internalID == videoComponentID })
      .flatMap { wrapper in
        guard case .conicGradientFill(let component) = wrapper.videoComponent else { return nil }
        return component
      }
  }

  private var centerX: Ldtx_Workspace_V4_Rational32 {
    component.map { $0.centerX ?? .init() }
      ?? .with {
        $0.set(num: 1, den: 2)
      }
  }

  private var centerY: Ldtx_Workspace_V4_Rational32 {
    component.map { $0.centerY ?? .init() }
      ?? .with {
        $0.set(num: 1, den: 2)
      }
  }

  private var startAngleRadians: Ldtx_Workspace_V4_Rational32 {
    component.map { $0.startAngleRadians ?? .init() }
      ?? .with {
        $0.set(num: 0, den: 1)
      }
  }

  private var startColor: Color {
    component.flatMap { ($0.startExtendedSrgbColor ?? .init()).extendedSRGBSwiftUIColor } ?? .black
  }

  private var endColor: Color {
    component.flatMap { ($0.endExtendedSrgbColor ?? .init()).extendedSRGBSwiftUIColor } ?? .white
  }

  var body: some View {
    Form {
      VideoComponentProgramLayers(
        stateService: stateService, appletData: appletData, componentID: videoComponentID)
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

        TextField(
          "Name",
          text: componentBinding(
            \.displayName, initial: component == nil ? "(invalid)" : "", undoManager: undoManager))
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
        LabeledContent("Start Angle") {
          Slider(
            value: componentBinding(
              \.startAngleRadians, initial: startAngleRadians, undoManager: undoManager
            ).sliderValue(denominator: 1_000_000), in: 0...(Double.pi * 2))
        }
        ColorPicker(
          "Start Color",
          selection: colorBinding(
            \.startExtendedSrgbColor, initial: startColor, undoManager: undoManager),
          supportsOpacity: true)
        ColorPicker(
          "End Color",
          selection: colorBinding(
            \.endExtendedSrgbColor, initial: endColor, undoManager: undoManager),
          supportsOpacity: true)
      }
      VideoComponentDeleteButton(stateService: stateService, componentID: videoComponentID)
    }
    .formStyle(.grouped)
    .disabled(stateService.isOutputActive || component == nil)
  }

  func componentBinding<Value>(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_FillConicGradientComponent, Value?>,
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
      Ldtx_Workspace_V4_FillConicGradientComponent, Ldtx_Workspace_V4_Color?
    >,
    initial: Color, undoManager: UndoManager?
  ) -> Binding<Color> {
    Binding(
      get: {
        component.flatMap { ($0[keyPath: keyPath] ?? .init()).extendedSRGBSwiftUIColor } ?? initial
      },
      set: { next in
        guard let value = Ldtx_Workspace_V4_Color(extendedSRGBSwiftUIColor: next) else { return }
        updateComponent(undoManager: undoManager) { $0[keyPath: keyPath] = value }
      })
  }

  private func updateComponent(
    undoManager: UndoManager?,
    _ mutation: (inout Ldtx_Workspace_V4_FillConicGradientComponent) -> Void
  ) {
    guard !stateService.isOutputActive else { return }
    var definition = stateService.workspaceDefinition
    guard
      let index = definition.videoComponents.firstIndex(where: { $0.internalID == videoComponentID }
      ),
      case .conicGradientFill(var component) = definition.videoComponents[index].videoComponent
    else { return }
    mutation(&component)
    definition.videoComponents[index].videoComponent = .conicGradientFill(component)
    stateService.editWorkspace(undoManager: undoManager) { workspace in
      workspace.definition = definition
    }
  }

  private var gradient: AngularGradient {
    AngularGradient(
      colors: [startColor, endColor],
      center: UnitPoint(
        x: centerX.double(defaultNumerator: 0, defaultDenominator: 1),
        y: centerY.double(defaultNumerator: 0, defaultDenominator: 1)),
      startAngle: .radians(startAngleRadians.double(defaultNumerator: 0, defaultDenominator: 1)),
      endAngle: .radians(
        startAngleRadians.double(defaultNumerator: 0, defaultDenominator: 1) + 2 * .pi))
  }
}

#if DEBUG
  #Preview("Default") {
    @Previewable @State var stateService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .conicGradientFillVideoComponent, internalID: 7))
    ConicGradientFillVideoComponentInspector(
      stateService: stateService, appletData: WorkspaceAppletData(), videoComponentID: 7
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  #Preview("Output Active") {
    @Previewable @State var stateService = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorSelector: .init(kind: .conicGradientFillVideoComponent, internalID: 7),
      isOutputActive: true)
    ConicGradientFillVideoComponentInspector(
      stateService: stateService, appletData: WorkspaceAppletData(), videoComponentID: 7
    )
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }
#endif
