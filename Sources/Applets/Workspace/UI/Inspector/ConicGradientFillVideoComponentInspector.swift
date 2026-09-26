// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

struct ConicGradientFillVideoComponentInspector: View {
  let uiState: WorkspaceUIState
  let videoComponentID: WorkspaceUIState.VideoComponentWrapper.ID

  private var component: Ldtx_Workspace_V4_FillConicGradientComponent? {
    uiState.findVideoComponent(id: videoComponentID)
  }

  private func updateComponent(
    _ mutation: (inout Ldtx_Workspace_V4_FillConicGradientComponent) -> Void
  ) {
    var definition = uiState.definition
    guard
      let index = definition.videoComponents.firstIndex(where: {
        $0.id == videoComponentID
      }),
      case .conicGradientFill(var component) = definition.videoComponents[index].definition
    else { return }
    mutation(&component)
    definition.videoComponents[index].definition = .conicGradientFill(component)
    uiState.definition = definition
  }

  var body: some View {
    Form {
      Section("Conic Gradient Fill") {
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
          "Start Angle",
          value: parameterBinding(\.startAngleRadians, initial: 0),
          range: 0...(Float.pi * 2))
        ProgramColorPicker(
          "Start Color",
          red: colorBinding(\.startColor, channel: \.red),
          green: colorBinding(\.startColor, channel: \.green),
          blue: colorBinding(\.startColor, channel: \.blue),
          alpha: colorBinding(\.startColor, channel: \.alpha)
        )
        ProgramColorPicker(
          "End Color",
          red: colorBinding(\.endColor, channel: \.red),
          green: colorBinding(\.endColor, channel: \.green),
          blue: colorBinding(\.endColor, channel: \.blue),
          alpha: colorBinding(\.endColor, channel: \.alpha)
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
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_FillConicGradientComponent, Float>, initial: Float
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
      Ldtx_Workspace_V4_FillConicGradientComponent, Ldtx_Workspace_V4_ExtendedSrgbColor
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
  #Preview("Conic Gradient Fill Inspector") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorKind: .conicGradientFillVideoComponent(7))
    ConicGradientFillVideoComponentInspector(
      uiState: uiState, videoComponentID: .conicGradientFill(7))
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }
#endif
