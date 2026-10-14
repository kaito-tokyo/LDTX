// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProgramRuntime
import MetalKit

public final class ProgramCanvasPairedPreview: NSView {
  public let metalView: MTKView
  public var padding: CGFloat = 0 {
    didSet { needsLayout = true }
  }
  private let previewDelegate: any MTKViewDelegate
  private let onSelectLandscape: () -> Void
  private let onSelectPortrait: () -> Void

  public init(
    device: MTLDevice?, delegate: any MTKViewDelegate, onSelectLandscape: @escaping () -> Void,
    onSelectPortrait: @escaping () -> Void
  ) {
    metalView = MTKView(frame: .zero, device: device)
    previewDelegate = delegate
    self.onSelectLandscape = onSelectLandscape
    self.onSelectPortrait = onSelectPortrait
    super.init(frame: .zero)
    metalView.colorPixelFormat = .bgra8Unorm
    metalView.framebufferOnly = false
    metalView.autoResizeDrawable = true
    metalView.enableSetNeedsDisplay = false
    metalView.isPaused = false
    metalView.preferredFramesPerSecond = 15
    wantsLayer = true
    layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    metalView.clearColor = MTLClearColorMake(0, 0, 0, 0)
    metalView.delegate = delegate
    metalView.wantsLayer = true
    metalView.layer?.isOpaque = false
    metalView.layer?.backgroundColor = nil
    addSubview(metalView)
    metalView.addGestureRecognizer(
      NSClickGestureRecognizer(target: self, action: #selector(clicked(_:))))
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    setAccessibilityLabel("Landscape and Portrait preview")
    setAccessibilityIdentifier("canvasPairPreview")
    setAccessibilityCustomActions([
      NSAccessibilityCustomAction(
        name: String(localized: "Select Landscape"), target: self,
        selector: #selector(selectLandscape)),
      NSAccessibilityCustomAction(
        name: String(localized: "Select Portrait"), target: self,
        selector: #selector(selectPortrait)),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
  }

  public override func layout() {
    super.layout()
    let ratio: CGFloat = 16.0 / 9.0 + 9.0 / 16.0
    let safeArea = safeAreaRect
    let inset = max(0, padding)
    let available = NSRect(
      x: safeArea.minX + min(inset, safeArea.width / 2),
      y: safeArea.minY + min(inset, safeArea.height / 2),
      width: max(0, safeArea.width - inset * 2),
      height: max(0, safeArea.height - inset * 2))
    let height = min(available.height, available.width / ratio)
    let width = height * ratio
    metalView.frame = NSRect(
      x: available.midX - width / 2, y: available.midY - height / 2,
      width: width, height: height)
  }

  @objc private func clicked(_ gesture: NSClickGestureRecognizer) {
    let point = gesture.location(in: metalView)
    selectCanvas(at: CGPoint(x: point.x, y: metalView.bounds.height - point.y))
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

  @objc private func selectLandscape() -> Bool {
    onSelectLandscape()
    return true
  }
  @objc private func selectPortrait() -> Bool {
    onSelectPortrait()
    return true
  }

  public func stop() {
    metalView.isPaused = true
    metalView.delegate = nil
  }
}
