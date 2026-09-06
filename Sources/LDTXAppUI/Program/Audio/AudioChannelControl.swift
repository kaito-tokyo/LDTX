// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXProgram
import MetalKit
import SwiftUI

struct AudioChannelControl: NSViewRepresentable {
  @Environment(\.isEnabled) private var isEnabled
  var label: String
  var value: Double
  var peakProvider: (() -> Float)?
  var onPreview: (Double) -> Void
  var onCommit: (Double) -> Void

  init(
    label: String,
    value: Double,
    peakProvider: (() -> Float)?,
    onPreview: @escaping (Double) -> Void,
    onCommit: @escaping (Double) -> Void
  ) {
    self.label = label
    self.value = value
    self.peakProvider = peakProvider
    self.onPreview = onPreview
    self.onCommit = onCommit
  }

  func makeNSView(context: Context) -> AudioChannelControlView {
    let row = AudioChannelControlView()
    row.configure(
      label: label,
      value: value,
      isEnabled: isEnabled,
      peakProvider: peakProvider,
      onPreview: onPreview,
      onCommit: onCommit
    )
    return row
  }

  func updateNSView(_ nsView: AudioChannelControlView, context: Context) {
    nsView.configure(
      label: label,
      value: value,
      isEnabled: isEnabled,
      peakProvider: peakProvider,
      onPreview: onPreview,
      onCommit: onCommit
    )
  }
}

final class AudioChannelControlView: NSView {
  private enum Layout {
    static let rowHeight: CGFloat = 48
    static let meterHeight: CGFloat = 18
    static let meterCornerRadius: CGFloat = 5
    static let rowSpacing: CGFloat = 6
  }

  private let slider = TrackingNSSlider(
    value: 0,
    minValue: ProgramPreferences.minimumAudioChannelGainDecibels,
    maxValue: ProgramPreferences.maximumAudioChannelGainDecibels,
    target: nil,
    action: nil
  )
  private var titleSpacingConstraint: NSLayoutConstraint?
  private let titleLabel = NSTextField(labelWithString: "")
  private let valueLabel = NSTextField(labelWithString: "")
  private let meterWindow = NSView()
  private var meterView: AudioPeakMeterMTKView?
  private var onPreview: (Double) -> Void = { _ in }
  private var onCommit: (Double) -> Void = { _ in }

  override var intrinsicContentSize: NSSize {
    NSSize(
      width: NSView.noIntrinsicMetric,
      height: titleLabel.stringValue.isEmpty ? Layout.meterHeight : Layout.rowHeight)
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  func configure(
    label: String,
    value: Double,
    isEnabled: Bool = true,
    peakProvider: (() -> Float)?,
    onPreview: @escaping (Double) -> Void,
    onCommit: @escaping (Double) -> Void
  ) {
    slider.isEnabled = isEnabled
    alphaValue = isEnabled ? 1 : 0.5
    titleLabel.stringValue = label
    titleLabel.isHidden = label.isEmpty
    titleSpacingConstraint?.isActive = !label.isEmpty
    invalidateIntrinsicContentSize()
    if let peakProvider {
      if meterView == nil {
        let meter = AudioPeakMeterMTKView()
        meter.translatesAutoresizingMaskIntoConstraints = false
        meter.isHidden = meter.device == nil
        meterWindow.addSubview(meter, positioned: .below, relativeTo: slider)
        NSLayoutConstraint.activate([
          meter.leadingAnchor.constraint(equalTo: meterWindow.leadingAnchor),
          meter.trailingAnchor.constraint(equalTo: meterWindow.trailingAnchor),
          meter.topAnchor.constraint(equalTo: meterWindow.topAnchor),
          meter.bottomAnchor.constraint(equalTo: meterWindow.bottomAnchor),
        ])
        meterView = meter
      }
      meterView?.peakProvider = peakProvider
    } else {
      meterView?.isPaused = true
      meterView?.removeFromSuperview()
      meterView = nil
    }
    self.onPreview = onPreview
    self.onCommit = onCommit
    if !slider.isEditing {
      setValue(value)
    } else {
      updateValueLabel(slider.doubleValue)
    }
  }

  func setValue(_ value: Double) {
    let decibels = ProgramPreferences.audioChannelGainDecibels(fromLinearGain: value)
    setDecibelValue(decibels)
  }

  private func setup() {
    translatesAutoresizingMaskIntoConstraints = false

    titleLabel.lineBreakMode = .byTruncatingMiddle
    titleLabel.maximumNumberOfLines = 1
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    slider.isContinuous = true
    slider.numberOfTickMarks = 0
    slider.translatesAutoresizingMaskIntoConstraints = false
    slider.controlSize = .small
    slider.alphaValue = 0.92
    slider.target = self
    slider.action = #selector(sliderChanged(_:))
    slider.onEditingEnded = { [weak self] slider in
      self?.sliderEditingEnded(slider)
    }

    valueLabel.alignment = .right
    valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    valueLabel.textColor = .secondaryLabelColor
    valueLabel.setContentHuggingPriority(.required, for: .horizontal)
    valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    meterWindow.wantsLayer = true
    meterWindow.layer?.cornerRadius = Layout.meterCornerRadius
    meterWindow.layer?.masksToBounds = true
    meterWindow.translatesAutoresizingMaskIntoConstraints = false

    meterWindow.addSubview(slider)

    for view in [titleLabel, meterWindow, valueLabel] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }

    let preferredMeterWidth = meterWindow.widthAnchor.constraint(
      greaterThanOrEqualToConstant: 190
    )
    preferredMeterWidth.priority = .defaultLow

    // Reserve the widest dB text in the slider's range so changing the
    // sign or digit count never changes the meter width.
    let decibelLabels = [
      String(format: "%+.1f dB", ProgramPreferences.minimumAudioChannelGainDecibels),
      String(format: "%+.1f dB", ProgramPreferences.maximumAudioChannelGainDecibels),
      "0.0 dB",
    ]
    let valueWidth = ceil(decibelLabels.map {
      ($0 as NSString).size(withAttributes: [.font: valueLabel.font!]).width
    }.max() ?? 0)

    NSLayoutConstraint.activate([
      valueLabel.widthAnchor.constraint(equalToConstant: valueWidth),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
      titleLabel.topAnchor.constraint(equalTo: topAnchor),
      meterWindow.leadingAnchor.constraint(equalTo: leadingAnchor),
      meterWindow.trailingAnchor.constraint(equalTo: valueLabel.leadingAnchor, constant: -8),
      meterWindow.bottomAnchor.constraint(equalTo: bottomAnchor),
      slider.leadingAnchor.constraint(equalTo: meterWindow.leadingAnchor, constant: 10),
      slider.trailingAnchor.constraint(equalTo: meterWindow.trailingAnchor, constant: -10),
      slider.centerYAnchor.constraint(equalTo: meterWindow.centerYAnchor),
      meterWindow.heightAnchor.constraint(equalToConstant: Layout.meterHeight),
      preferredMeterWidth,
      valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
      valueLabel.centerYAnchor.constraint(equalTo: meterWindow.centerYAnchor),
    ])
    titleSpacingConstraint = titleLabel.bottomAnchor.constraint(
      equalTo: meterWindow.topAnchor, constant: -Layout.rowSpacing)
    titleSpacingConstraint?.isActive = true
  }

  private func setDecibelValue(_ decibels: Double) {
    slider.doubleValue = decibels
    updateValueLabel(decibels)
  }

  private func updateValueLabel(_ decibels: Double) {
    let clampedDecibels = min(
      max(decibels, ProgramPreferences.minimumAudioChannelGainDecibels),
      ProgramPreferences.maximumAudioChannelGainDecibels
    )
    if abs(clampedDecibels) < 0.05 {
      valueLabel.stringValue = "0.0 dB"
    } else {
      valueLabel.stringValue = String(format: "%+.1f dB", clampedDecibels)
    }
  }

  @objc private func sliderChanged(_ sender: TrackingNSSlider) {
    let decibels = sender.doubleValue
    let gain = ProgramPreferences.linearAudioChannelGain(fromDecibels: decibels)
    setDecibelValue(decibels)
    onPreview(gain)
    if !sender.isEditing {
      onCommit(gain)
    }
  }

  private func sliderEditingEnded(_ sender: TrackingNSSlider) {
    let decibels = sender.doubleValue
    let gain = ProgramPreferences.linearAudioChannelGain(fromDecibels: decibels)
    setDecibelValue(decibels)
    onPreview(gain)
    onCommit(gain)
  }

}

#if DEBUG
  #Preview("Audio Channel Control") {
    AudioChannelControlPreviewHost()
      .padding()
      .frame(width: 520, height: 64)
  }

  private struct AudioChannelControlPreviewHost: View {
    @State private var gain = 1.0

    var body: some View {
      AudioChannelControl(
        label: "Mic 1",
        value: gain,
        peakProvider: { 0.64 },
        onPreview: { gain = $0 },
        onCommit: { gain = $0 }
      )
    }
  }
#endif

final class AudioPeakMeterMTKView: MTKView, MTKViewDelegate {
  private enum MeterScale {
    static let minimumDecibels: Float = -60
    static let maximumDecibels: Float = 0
    static let alignmentDecibels: Float = -18
    static let permittedMaximumDecibels: Float = -9
    static let releaseDecibelsPerSecond: Float = 20 / 1.7
  }

  private enum FrameRate {
    static let preferred = 15
  }

  var peakProvider: (() -> Float)?

  private var commandQueue: MTLCommandQueue?
  private var pipelineState: MTLRenderPipelineState?
  private var displayedDecibels: Float = MeterScale.minimumDecibels
  private var lastDrawTimeSeconds: TimeInterval?

  init() {
    let metalDevice = MTLCreateSystemDefaultDevice()
    super.init(frame: .zero, device: metalDevice)
    guard let metalDevice else {
      return
    }
    framebufferOnly = true
    colorPixelFormat = .bgra8Unorm
    clearColor = MTLClearColorMake(0.08, 0.085, 0.09, 1.0)
    preferredFramesPerSecond = FrameRate.preferred
    enableSetNeedsDisplay = false
    isPaused = false
    commandQueue = metalDevice.makeCommandQueue()
    pipelineState = Self.makePipelineState(device: metalDevice, pixelFormat: colorPixelFormat)
    delegate = self
  }

  required init(coder: NSCoder) {
    let metalDevice = MTLCreateSystemDefaultDevice()
    super.init(coder: coder)
    device = metalDevice
    guard let metalDevice else {
      return
    }
    framebufferOnly = true
    colorPixelFormat = .bgra8Unorm
    clearColor = MTLClearColorMake(0.08, 0.085, 0.09, 1.0)
    preferredFramesPerSecond = FrameRate.preferred
    enableSetNeedsDisplay = false
    isPaused = false
    commandQueue = metalDevice.makeCommandQueue()
    pipelineState = Self.makePipelineState(device: metalDevice, pixelFormat: colorPixelFormat)
    delegate = self
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard device != nil,
      let commandQueue,
      let pipelineState,
      let passDescriptor = currentRenderPassDescriptor,
      let drawable = currentDrawable,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
    else {
      return
    }

    let currentTimeSeconds = ProcessInfo.processInfo.systemUptime
    let elapsedSeconds = Float(currentTimeSeconds - (lastDrawTimeSeconds ?? currentTimeSeconds))
    lastDrawTimeSeconds = currentTimeSeconds

    let rawPeak = max(peakProvider?() ?? 0, 0)
    let measuredDecibels =
      rawPeak > 0
      ? 20 * log10(rawPeak)
      : MeterScale.minimumDecibels
    if measuredDecibels >= displayedDecibels {
      displayedDecibels = measuredDecibels
    } else {
      displayedDecibels = max(
        measuredDecibels,
        displayedDecibels - MeterScale.releaseDecibelsPerSecond * max(elapsedSeconds, 0)
      )
    }
    let displayDecibels = min(
      max(displayedDecibels, MeterScale.minimumDecibels), MeterScale.maximumDecibels)
    let level = normalizedLevel(for: displayDecibels)
    let yellowStart = normalizedLevel(for: MeterScale.alignmentDecibels)
    let redStart = normalizedLevel(for: MeterScale.permittedMaximumDecibels)

    var vertices: [Float] = []
    appendRect(
      x0: -1,
      x1: 1,
      y0: -1,
      y1: 1,
      color: (0.10, 0.11, 0.12, 1.0),
      to: &vertices
    )
    appendSegment(
      from: 0,
      to: min(level, yellowStart),
      rangeStart: 0,
      rangeEnd: yellowStart,
      color: (0.20, 0.78, 0.42, 1.0),
      to: &vertices
    )
    appendSegment(
      from: yellowStart,
      to: min(level, redStart),
      rangeStart: yellowStart,
      rangeEnd: redStart,
      color: (0.95, 0.72, 0.25, 1.0),
      to: &vertices
    )
    appendSegment(
      from: redStart,
      to: level,
      rangeStart: redStart,
      rangeEnd: 1,
      color: (0.95, 0.28, 0.24, 1.0),
      to: &vertices
    )

    encoder.setRenderPipelineState(pipelineState)
    let vertexCount = vertices.count / 8
    vertices.withUnsafeBytes { buffer in
      encoder.setVertexBytes(buffer.baseAddress!, length: buffer.count, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }
    encoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private static func makePipelineState(
    device: MTLDevice,
    pixelFormat: MTLPixelFormat
  ) -> MTLRenderPipelineState? {
    do {
      guard let library = AppUIMetalLibrary.makeLibrary(device: device) else {
        return nil
      }
      guard let vertexFunction = library.makeFunction(name: "audio_peak_meter_vertex"),
        let fragmentFunction = library.makeFunction(name: "audio_peak_meter_fragment")
      else {
        return nil
      }
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = vertexFunction
      descriptor.fragmentFunction = fragmentFunction
      descriptor.colorAttachments[0].pixelFormat = pixelFormat
      return try device.makeRenderPipelineState(descriptor: descriptor)
    } catch {
      return nil
    }
  }

  private func normalizedLevel(for decibels: Float) -> Float {
    min(
      max(
        (decibels - MeterScale.minimumDecibels)
          / (MeterScale.maximumDecibels - MeterScale.minimumDecibels),
        0
      ),
      1
    )
  }

  private func appendSegment(
    from start: Float,
    to end: Float,
    rangeStart: Float,
    rangeEnd: Float,
    color: (Float, Float, Float, Float),
    to vertices: inout [Float]
  ) {
    guard end > start else { return }
    let width = max(rangeEnd - rangeStart, 0.000_1)
    let x0 = -1 + 2 * ((start - rangeStart) / width * (rangeEnd - rangeStart) + rangeStart)
    let x1 = -1 + 2 * ((end - rangeStart) / width * (rangeEnd - rangeStart) + rangeStart)
    appendRect(x0: x0, x1: x1, y0: -1, y1: 1, color: color, to: &vertices)
  }

  private func appendRect(
    x0: Float,
    x1: Float,
    y0: Float,
    y1: Float,
    color: (Float, Float, Float, Float),
    to vertices: inout [Float]
  ) {
    let rectVertices: [Float] = [
      x0, y0, 0, 1, color.0, color.1, color.2, color.3,
      x1, y0, 0, 1, color.0, color.1, color.2, color.3,
      x0, y1, 0, 1, color.0, color.1, color.2, color.3,
      x1, y0, 0, 1, color.0, color.1, color.2, color.3,
      x1, y1, 0, 1, color.0, color.1, color.2, color.3,
      x0, y1, 0, 1, color.0, color.1, color.2, color.3,
    ]
    vertices.append(contentsOf: rectVertices)
  }
}

final class TrackingNSSlider: NSSlider {
  var onEditingEnded: ((TrackingNSSlider) -> Void)?
  private(set) var isEditing = false

  override func mouseDown(with event: NSEvent) {
    isEditing = true
    super.mouseDown(with: event)
    isEditing = false
    onEditingEnded?(self)
  }
}
