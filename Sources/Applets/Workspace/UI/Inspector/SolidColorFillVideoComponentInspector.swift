// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import LDTXProtos
import SwiftUI

struct SolidColorFillVideoComponentInspector: View {
  let uiState: WorkspaceUIState
  let videoComponentID: WorkspaceUIState.VideoComponentWrapper.ID

  private var component: Ldtx_Workspace_V4_FillSolidColorComponent? {
    uiState.findVideoComponent(id: videoComponentID)
  }

  var body: some View {
    Section("Solid Color Fill") {
      if component == nil {
        Label("Invalid component", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
      TextField("Name", text: nameBinding)
      if let previewImage {
        HStack(alignment: .center, spacing: 12) {
          fillPreview(previewImage)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
          fillPreview(previewImage)
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .frame(height: 96)
        }
      }
      ProgramColorPicker(
        "Color",
        red: colorBinding(\.color, channel: \.red),
        green: colorBinding(\.color, channel: \.green),
        blue: colorBinding(\.color, channel: \.blue),
        alpha: colorBinding(\.color, channel: \.alpha)
      )
    }
    .disabled(uiState.isRecording || component == nil)
  }

  private var previewImage: CGImage? {
    guard let color = component?.color,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    func channel(_ value: Float) -> CGFloat {
      guard value.isFinite else { return 0 }
      return CGFloat(min(max(value, 0), 1))
    }

    context.setFillColor(
      CGColor(
        srgbRed: channel(color.red), green: channel(color.green), blue: channel(color.blue),
        alpha: channel(color.alpha)))
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    return context.makeImage()
  }

  private func fillPreview(_ image: CGImage) -> some View {
    Image(decorative: image, scale: 1)
      .resizable()
      .interpolation(.high)
      .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  private var nameBinding: Binding<String> {
    Binding(
      get: { component?.displayName ?? "Invalid" },
      set: { name in
        updateComponent { $0.displayName = name }
      }
    )
  }

  private func colorBinding(
    _ colorKeyPath: WritableKeyPath<
      Ldtx_Workspace_V4_FillSolidColorComponent, Ldtx_Workspace_V4_ExtendedSrgbColor
    >,
    channel: WritableKeyPath<Ldtx_Workspace_V4_ExtendedSrgbColor, Float>
  ) -> Binding<Float> {
    Binding(
      get: { component?[keyPath: colorKeyPath][keyPath: channel] ?? 0 },
      set: { value in
        updateComponent { $0[keyPath: colorKeyPath][keyPath: channel] = value }
      }
    )
  }

  private func updateComponent(
    _ mutation: (inout Ldtx_Workspace_V4_FillSolidColorComponent) -> Void
  ) {
    var definition = uiState.definition
    guard
      let index = definition.videoComponents.firstIndex(where: {
        $0.id == videoComponentID
      }),
      case .solidColorFill(var component) = definition.videoComponents[index].definition
    else { return }
    mutation(&component)
    definition.videoComponents[index].definition = .solidColorFill(component)
    uiState.definition = definition
  }
}

#if DEBUG
  #Preview("Solid Color Fill Inspector") {
    @Previewable @State var uiState = WorkspaceSidebarPreviewFixtures.makeUIState(
      inspectorKind: .solidColorFillVideoComponent(4))
    Form {
      SolidColorFillVideoComponentInspector(
        uiState: uiState, videoComponentID: .solidColorFill(4))
    }
    .formStyle(.grouped)
    .padding(16)
    .frame(width: 480, height: 640, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }
#endif
