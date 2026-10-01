// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletInterface
import MetalKit
import SwiftUI

struct CanvasPairPreview: View {
  @Environment(\.displayScale) private var displayScale
  @Binding var prefersColor: Bool
  let landscapeRuntime: ProgramRuntime
  let portraitRuntime: ProgramRuntime
  let landscapeSize: CGSize
  let portraitSize: CGSize
  var activeProgramCanvasRole: Binding<ProgramCanvasRole> = .constant(.landscape)

  var body: some View {
    GeometryReader { proxy in
      ProgramPairMetalView(
        landscapeRuntime: landscapeRuntime,
        portraitRuntime: portraitRuntime,
        landscapeSize: landscapeSize,
        portraitSize: portraitSize,
        prefersColor: prefersColor
      )
      .contentShape(Rectangle())
      .gesture(
        SpatialTapGesture().onEnded { value in
          let scale = max(displayScale, 1)
          let regions = ProgramPairPreviewRegions(
            drawable: CGSize(
              width: proxy.size.width * scale,
              height: proxy.size.height * scale
            ),
            landscapeSize: landscapeSize,
            portraitSize: portraitSize
          )
          let location = CGPoint(x: value.location.x * scale, y: value.location.y * scale)
          if regions.landscape.contains(location) {
            activeProgramCanvasRole.wrappedValue = .landscape
          } else if regions.portrait.contains(location) {
            activeProgramCanvasRole.wrappedValue = .portrait
          } else {
            prefersColor.toggle()
          }
        }
      )
    }
    .aspectRatio(
      landscapeSize.width / max(1, landscapeSize.height)
        + portraitSize.width / max(1, portraitSize.height), contentMode: .fit
    )
    .accessibilityValue(prefersColor ? "Accurate" : "Lightweight")
    .accessibilityAction { prefersColor.toggle() }
    .accessibilityAction(named: "Select Landscape") {
      activeProgramCanvasRole.wrappedValue = .landscape
    }
    .accessibilityAction(named: "Select Portrait") {
      activeProgramCanvasRole.wrappedValue = .portrait
    }
    .accessibilityLabel("Canvas Preview")
    .accessibilityIdentifier("canvasPairPreview")
  }
}

private struct ProgramPairMetalView: NSViewRepresentable {
  let landscapeRuntime: ProgramRuntime
  let portraitRuntime: ProgramRuntime
  let landscapeSize: CGSize
  let portraitSize: CGSize
  let prefersColor: Bool

  func makeCoordinator() -> ProgramPairPreviewRenderer {
    ProgramPairPreviewRenderer(
      landscapeRuntime: landscapeRuntime,
      portraitRuntime: portraitRuntime,
      landscapeSize: landscapeSize,
      portraitSize: portraitSize,
      prefersColor: prefersColor
    )
  }

  func makeNSView(context: Context) -> MTKView {
    let view = ProgramPreviewMTKView(frame: .zero, device: context.coordinator.device)
    view.colorPixelFormat = .bgra8Unorm
    view.framebufferOnly = false
    view.autoResizeDrawable = false
    view.enableSetNeedsDisplay = false
    view.isPaused = false
    view.preferredFramesPerSecond = 15
    view.clearColor = MTLClearColorMake(0, 0, 0, 0)
    view.layer?.isOpaque = false
    view.layer?.backgroundColor = nil
    view.delegate = context.coordinator
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.image)
    view.setAccessibilityLabel("Landscape and Portrait preview")
    view.setAccessibilityIdentifier("canvasPairPreview")
    context.coordinator.start()
    return view
  }

  func updateNSView(_ view: MTKView, context: Context) {
    context.coordinator.update(
      landscapeSize: landscapeSize,
      portraitSize: portraitSize,
      prefersColor: prefersColor
    )
  }

  static func dismantleNSView(_ view: MTKView, coordinator: ProgramPairPreviewRenderer) {
    view.isPaused = true
    view.delegate = nil
    coordinator.stop()
  }
}
