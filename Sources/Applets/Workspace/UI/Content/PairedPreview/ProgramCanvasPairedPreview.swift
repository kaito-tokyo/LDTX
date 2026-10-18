// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgramRuntime
import MetalKit
import SwiftUI

/// Retains the document's Metal surface and delegate independently of SwiftUI view updates.
@MainActor
public final class ProgramCanvasPairedPreview {
  public var attachWindow: ((NSWindow?) -> NSResponder?)?
  public let metalView: MTKView
  private let previewDelegate: any MTKViewDelegate
  fileprivate let onSelectLandscape: () -> Void
  fileprivate let onSelectPortrait: () -> Void
  var accessibilityImage: PreviewAccessibilityImageStore? {
    (previewDelegate as? any ProgramPreviewAccessibilityImageSource)?.accessibilityImage
  }

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
      PairedProgramPreview(preview: self)
        .frame(width: height * ratio, height: height)
        .contentShape(Rectangle())
        .onTapGesture { point in self.selectCanvas(at: point) }
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
    accessibilityImage?.clear()
    metalView.isPaused = true
    metalView.delegate = nil
  }
}

private struct PairedProgramPreview: NSViewRepresentable {
  let preview: ProgramCanvasPairedPreview

  func makeNSView(context: Context) -> PreviewHost {
    PreviewHost(preview: preview)
  }
  func updateNSView(_ view: PreviewHost, context: Context) { view.attach() }
  static func dismantleNSView(_ view: PreviewHost, coordinator: ()) { view.detach() }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: PreviewHost, context: Context) -> CGSize?
  {
    CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
  }

  final class PreviewHost: NSView {
    let preview: ProgramCanvasPairedPreview
    private weak var responderHost: NSWindow?
    private var documentActions: NSResponder?
    private lazy var imageElement = PreviewImageAccessibilityElement(host: self,
      store: preview.accessibilityImage,
      selectLandscape: preview.onSelectLandscape, selectPortrait: preview.onSelectPortrait)

    override func accessibilityChildren() -> [Any]? { [imageElement] }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
      MainActor.assumeIsolated { imageElement }
    }

    init(preview: ProgramCanvasPairedPreview) {
      self.preview = preview
      super.init(frame: .zero)
      setAccessibilityElement(false)
      let metalView = preview.metalView
      metalView.setAccessibilityElement(false)
      metalView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(metalView)
      NSLayoutConstraint.activate([
        metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
        metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
        metalView.topAnchor.constraint(equalTo: topAnchor),
        metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      attach()
    }

    func attach() {
      guard responderHost !== window || documentActions == nil else { return }
      detach()
      guard let window, let actions = preview.attachWindow?(window) else { return }
      actions.nextResponder = window.nextResponder
      window.nextResponder = actions
      documentActions = actions
      responderHost = window
    }

    func detach() {
      if let responderHost, responderHost.nextResponder === documentActions {
        responderHost.nextResponder = documentActions?.nextResponder
      }
      documentActions?.nextResponder = nil
      documentActions = nil
      responderHost = nil
    }
  }
}
