// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

struct RadialGradientFillVideoComponentInspector: View {
  let uiState: WorkspaceUIState
  let videoComponentID: WorkspaceUIState.VideoComponentWrapper.ID

  private var component: Ldtx_Workspace_V4_FillRadialGradientComponent? {
    uiState.findVideoComponent(id: videoComponentID)
  }

  private func updateComponent(
    _ mutation: (inout Ldtx_Workspace_V4_FillRadialGradientComponent) -> Void
  ) {
    var definition = uiState.definition
    guard
      let index = definition.videoComponents.firstIndex(where: {
        $0.id == videoComponentID
      }),
      case .radialGradientFill(var component) = definition.videoComponents[index].definition
    else { return }
    mutation(&component)
    definition.videoComponents[index].definition = .radialGradientFill(component)
    uiState.definition = definition
  }

  var body: some View {
    Form {
      Section("Radial Gradient Fill") {
        if component == nil {
          Label("Invalid component", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
        TextField("Name", text: nameBinding)
        ProgramParameterSlider(
          "Center X", value: parameterBinding(\.centerX, initial: 0.5),
          range: 0...1)
        ProgramParameterSlider(
          "Center Y", value: parameterBinding(\.centerY, initial: 0.5),
          range: 0...1)
        ProgramParameterSlider(
          "Inner Radius", value: parameterBinding(\.innerRadius, initial: 0),
          range: 0...1)
        ProgramParameterSlider(
          "Outer Radius", value: parameterBinding(\.outerRadius, initial: 0.72),
          range: 0.01...1)
        ProgramColorPicker(
          "Inner Color",
          red: colorBinding(\.innerColor, channel: \.red),
          green: colorBinding(\.innerColor, channel: \.green),
          blue: colorBinding(\.innerColor, channel: \.blue),
          alpha: colorBinding(\.innerColor, channel: \.alpha)
        )
        ProgramColorPicker(
          "Outer Color",
          red: colorBinding(\.outerColor, channel: \.red),
          green: colorBinding(\.outerColor, channel: \.green),
          blue: colorBinding(\.outerColor, channel: \.blue),
          alpha: colorBinding(\.outerColor, channel: \.alpha)
        )
      }
    }
    .formStyle(.grouped)
    .disabled(uiState.isOutputActive || component == nil)
  }

  private var nameBinding: Binding<String> {
    Binding(
      get: { component?.displayName ?? "Invalid" },
      set: { name in
        guard component != nil else { return }
        updateComponent { component in
          component.displayName = name
        }
      }
    )
  }

  private func parameterBinding(
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_FillRadialGradientComponent, Float>, initial: Float
  ) -> Binding<Float> {
    Binding(
      get: { component?[keyPath: keyPath] ?? initial },
      set: { value in
        guard component != nil else { return }
        updateComponent { component in
          component[keyPath: keyPath] = value
        }
      }
    )
  }

  private func colorBinding(
    _ colorKeyPath: WritableKeyPath<
      Ldtx_Workspace_V4_FillRadialGradientComponent, Ldtx_Workspace_V4_ExtendedSrgbColor
    >,
    channel: WritableKeyPath<Ldtx_Workspace_V4_ExtendedSrgbColor, Float>
  ) -> Binding<Float> {
    Binding(
      get: { component?[keyPath: colorKeyPath][keyPath: channel] ?? 0 },
      set: { value in
        guard component != nil else { return }
        updateComponent { component in
          component[keyPath: colorKeyPath][keyPath: channel] = value
        }
      }
    )
  }
}

#if DEBUG
  #Preview("Radial Gradient Fill Inspector") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorKind: .radialGradientFillVideoComponent(6))
    RadialGradientFillVideoComponentInspector(
      uiState: uiState, videoComponentID: .radialGradientFill(6))
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }
#endif
