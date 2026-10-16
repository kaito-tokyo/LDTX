// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgramRuntime
import MetalKit
import SwiftUI

/// Retains the document's Metal surface and delegate independently of SwiftUI view updates.
@MainActor
public final class ProgramCanvasPairedPreview {
  public let metalView: MTKView
  private let previewDelegate: any MTKViewDelegate
  private let onSelectLandscape: () -> Void
  private let onSelectPortrait: () -> Void

  public init(
    metalView: MTKView, delegate: any MTKViewDelegate, onSelectLandscape: @escaping () -> Void,
    onSelectPortrait: @escaping () -> Void
  ) {
    self.metalView = metalView
    previewDelegate = delegate
    self.onSelectLandscape = onSelectLandscape
    self.onSelectPortrait = onSelectPortrait
    metalView.colorPixelFormat = .bgra8Unorm
    metalView.framebufferOnly = false
    metalView.autoResizeDrawable = true
    metalView.enableSetNeedsDisplay = false
    metalView.isPaused = false
    metalView.preferredFramesPerSecond = 15
    metalView.clearColor = MTLClearColorMake(0, 0, 0, 0)
    metalView.delegate = delegate
    metalView.wantsLayer = true
    metalView.layer?.isOpaque = false
    metalView.layer?.backgroundColor = nil
  }

  var content: some View {
    GeometryReader { geometry in
      let ratio: CGFloat = 16.0 / 9.0 + 9.0 / 16.0
      let height = min(max(0, geometry.size.height - 24), max(0, geometry.size.width - 24) / ratio)
      MetalPreview(view: self.metalView)
        .frame(width: height * ratio, height: height)
        .contentShape(Rectangle())
        .onTapGesture { point in self.selectCanvas(at: point) }
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel("Landscape and Portrait preview")
        .accessibilityIdentifier("canvasPairPreview")
        .accessibilityAction(named: Text("Select Landscape"), self.onSelectLandscape)
        .accessibilityAction(named: Text("Select Portrait"), self.onSelectPortrait)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(.background)
  }

  /// Accepts a point in the drawable's top-left coordinate system, measured in points.
  public func selectCanvas(at point: CGPoint) {
    let regions = ProgramPairPreviewRegions(
      drawable: metalView.convertToBacking(metalView.bounds).size,
      landscapeSize: CGSize(width: 16, height: 9), portraitSize: CGSize(width: 9, height: 16))
    let point = metalView.convertToBacking(point)
    if regions.landscape.contains(point) {
      onSelectLandscape()
    } else if regions.portrait.contains(point) {
      onSelectPortrait()
    }
  }

  public func stop() {
    metalView.isPaused = true
    metalView.delegate = nil
  }
}

private struct MetalPreview: NSViewRepresentable {
  let view: MTKView
  func makeNSView(context: Context) -> MTKView { view }
  func updateNSView(_ view: MTKView, context: Context) {}
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTKView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
  }
}
