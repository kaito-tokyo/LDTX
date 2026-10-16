// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import MetalKit
import SwiftUI

struct AudioChannelControl: View {
  @Binding var value: Double
  let peakProvider: () -> Float
  var showsValue = true
  var title = "Gain"

  var body: some View {
    HStack(spacing: 8) {
      Slider(value: $value, in: -80...20)
        .accessibilityLabel(title)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .background {
          AudioPeakMeter(peakProvider: peakProvider)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
      if showsValue {
        Text(value, format: .number.precision(.fractionLength(1)))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: 44, alignment: .trailing)
        Text("dB").foregroundStyle(.secondary)
      }
    }
  }
}

private struct AudioPeakMeter: NSViewRepresentable {
  let peakProvider: () -> Float
  func makeNSView(context: Context) -> AudioPeakMeterMTKView {
    let view = AudioPeakMeterMTKView()
    view.peakProvider = peakProvider
    return view
  }
  func updateNSView(_ view: AudioPeakMeterMTKView, context: Context) {
    view.peakProvider = peakProvider
  }
  static func dismantleNSView(_ view: AudioPeakMeterMTKView, coordinator: ()) {
    view.isPaused = true
    view.peakProvider = nil
  }
}

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

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if let window {
      NotificationCenter.default.removeObserver(
        self, name: NSWindow.willCloseNotification, object: window)
    }
    super.viewWillMove(toWindow: newWindow)
    isPaused = true
    if let newWindow {
      NotificationCenter.default.addObserver(
        self, selector: #selector(windowWillClose(_:)),
        name: NSWindow.willCloseNotification, object: newWindow)
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    lastDrawTimeSeconds = nil
    isPaused = window == nil || device == nil
  }

  @objc private func windowWillClose(_ notification: Notification) {
    isPaused = true
    lastDrawTimeSeconds = nil
  }

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
    isPaused = true
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
    isPaused = true
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
