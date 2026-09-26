// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import SwiftUI

struct LinearGradientFillVideoComponentInspector: View {
  let uiState: WorkspaceUIState
  let videoComponentID: WorkspaceUIState.VideoComponentWrapper.ID

  private var component: Ldtx_Workspace_V4_FillLinearGradientComponent? {
    uiState.findVideoComponent(id: videoComponentID)
  }

  private func updateComponent(
    _ mutation: (inout Ldtx_Workspace_V4_FillLinearGradientComponent) -> Void
  ) {
    var definition = uiState.definition
    guard
      let index = definition.videoComponents.firstIndex(where: {
        $0.id == videoComponentID
      }),
      case .linearGradientFill(var component) = definition.videoComponents[index].definition
    else { return }
    mutation(&component)
    definition.videoComponents[index].definition = .linearGradientFill(component)
    uiState.definition = definition
  }

  var body: some View {
    Section("Linear Gradient Fill") {
      if component == nil {
        Label("Invalid component", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
      TextField("Name", text: nameBinding)
      ProgramParameterSlider(
        "Start X", value: parameterBinding(\.startX, initial: 0),
        range: 0...1)
      ProgramParameterSlider(
        "Start Y", value: parameterBinding(\.startY, initial: 0),
        range: 0...1)
      ProgramParameterSlider(
        "End X", value: parameterBinding(\.endX, initial: 1),
        range: 0...1)
      ProgramParameterSlider(
        "End Y", value: parameterBinding(\.endY, initial: 1),
        range: 0...1)
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
    .disabled(uiState.isRecording || component == nil)
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
    _ keyPath: WritableKeyPath<Ldtx_Workspace_V4_FillLinearGradientComponent, Float>, initial: Float
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
      Ldtx_Workspace_V4_FillLinearGradientComponent, Ldtx_Workspace_V4_ExtendedSrgbColor
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
  #Preview("Linear Gradient Fill Inspector") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorKind: .linearGradientFillVideoComponent(5))
    Form {
      LinearGradientFillVideoComponentInspector(
        uiState: uiState, videoComponentID: .linearGradientFill(5))
    }
    .formStyle(.grouped)
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }
#endif
