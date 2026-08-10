// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXFontRasterizer
import LDTXProgram
import Metal
import simd

enum MetalClockOverlayRendererError: Error, LocalizedError {
  case commandQueueCreationFailed
  case fontDataUnavailable
  case glyphAtlasCreationFailed
  case shaderLibraryUnavailable
  case shaderFunctionUnavailable
  case textureCreationFailed
  case glyphBufferCreationFailed
  case commandBufferCreationFailed
  case renderEncoderCreationFailed
  case renderFailed
  case invalidTextureSize

  var errorDescription: String? {
    switch self {
    case .commandQueueCreationFailed:
      "The Clock renderer could not create a Metal command queue."
    case .fontDataUnavailable:
      "The bundled Noto Sans font could not be read."
    case .glyphAtlasCreationFailed:
      "The Clock renderer could not create its glyph atlas."
    case .shaderLibraryUnavailable:
      "The Clock Metal shader library is unavailable."
    case .shaderFunctionUnavailable:
      "The Clock Metal shader functions are unavailable."
    case .textureCreationFailed:
      "The Clock renderer could not allocate an overlay texture."
    case .glyphBufferCreationFailed:
      "The Clock renderer could not allocate its glyph instance buffer."
    case .commandBufferCreationFailed:
      "The Clock renderer could not create a command buffer."
    case .renderEncoderCreationFailed:
      "The Clock renderer could not create a render encoder."
    case .renderFailed:
      "The Clock Metal render pass failed."
    case .invalidTextureSize:
      "The requested Clock overlay texture size is invalid."
    }
  }
}

final class MetalClockOverlayRenderer: ClockOverlayRendering, @unchecked Sendable {
  private struct GlyphMetric {
    var atlasRect: SIMD4<Float>
    var offset: SIMD2<Float>
    var size: SIMD2<Float>
    var advance: Float
  }

  private struct GlyphInstance {
    var destinationRect: SIMD4<Float>
    var atlasRect: SIMD4<Float>
  }

  private struct Uniforms {
    var foregroundColor: SIMD4<Float>
    var backgroundColor0: SIMD4<Float>
    var backgroundColor1: SIMD4<Float>
    var outlineColor0: SIMD4<Float>
    var outlineColor1: SIMD4<Float>
    var overlaySize: SIMD2<Float>
    var gradientDirection: SIMD2<Float>
    var outlineThickness: SIMD2<Float>
    var backgroundKind: UInt32
    var glyphCount: UInt32
  }

  private static let firstCodePoint: UInt32 = 0x20
  private static let glyphCount = 0x7f - Int(firstCodePoint)
  private static let atlasWidth = 2_048
  private static let atlasHeight = 1_024
  private static let atlasPixelHeight: Float = 96

  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let atlasTexture: MTLTexture
  private let metrics: [GlyphMetric]
  private let colorPipeline: MTLRenderPipelineState
  private let colorAlphaPipeline: MTLRenderPipelineState

  convenience init(device: MTLDevice) throws {
    guard let fontURL = NotoSansFontResources.bundledUprightVariableFontURL else {
      throw MetalClockOverlayRendererError.fontDataUnavailable
    }
    try self.init(device: device, fontURL: fontURL)
  }

  // Internal injection point for resource-failure tests. Runtime callers use
  // the bundled, verified Noto Sans asset through init(device:).
  init(device: MTLDevice, fontURL: URL) throws {
    guard let commandQueue = device.makeCommandQueue() else {
      throw MetalClockOverlayRendererError.commandQueueCreationFailed
    }
    self.device = device
    self.commandQueue = commandQueue

    let atlas = try Self.makeAtlas(device: device, fontURL: fontURL)
    atlasTexture = atlas.texture
    metrics = atlas.metrics

    let library = try Self.makeShaderLibrary(device: device)
    guard let vertex = library.makeFunction(name: "clockOverlayVertex"),
      let colorFragment = library.makeFunction(name: "clockOverlayColorFragment"),
      let colorAlphaFragment = library.makeFunction(name: "clockOverlayColorAlphaFragment")
    else {
      throw MetalClockOverlayRendererError.shaderFunctionUnavailable
    }

    let colorDescriptor = MTLRenderPipelineDescriptor()
    colorDescriptor.label = "Clock Overlay RGB565"
    colorDescriptor.vertexFunction = vertex
    colorDescriptor.fragmentFunction = colorFragment
    colorDescriptor.colorAttachments[0].pixelFormat = .b5g6r5Unorm
    colorPipeline = try device.makeRenderPipelineState(descriptor: colorDescriptor)

    let colorAlphaDescriptor = MTLRenderPipelineDescriptor()
    colorAlphaDescriptor.label = "Clock Overlay RGB565 + R8 Alpha"
    colorAlphaDescriptor.vertexFunction = vertex
    colorAlphaDescriptor.fragmentFunction = colorAlphaFragment
    colorAlphaDescriptor.colorAttachments[0].pixelFormat = .b5g6r5Unorm
    colorAlphaDescriptor.colorAttachments[1].pixelFormat = .r8Unorm
    colorAlphaPipeline = try device.makeRenderPipelineState(descriptor: colorAlphaDescriptor)
  }

  func renderClockOverlay(_ request: ClockOverlayRenderRequest) throws -> ClockOverlayTexture {
    let request = request.normalizedForRendering
    guard request.pixelWidth > 0, request.pixelHeight > 0,
      request.pixelWidth <= 16_384,
      request.pixelHeight <= 16_384
    else {
      throw MetalClockOverlayRendererError.invalidTextureSize
    }

    let colorTexture = try makeTexture(
      pixelFormat: .b5g6r5Unorm,
      width: request.pixelWidth,
      height: request.pixelHeight
    )
    // An opaque background makes the final overlay opaque even when the
    // foreground itself is translucent. Only allocate R8 when the retained
    // layer needs alpha at the compositor boundary.
    let backgroundStyle = ClockBackgroundStyle.parse(request.component.background)
    let outlines = request.component.outlines.prefix(2).map {
      (
        max($0.thickness, 0),
        ClockCSSBackground.parseColor($0.color)?.simd ?? SIMD4<Float>(0, 0, 0, 1)
      )
    }
    let needsAlpha =
      backgroundStyle.minimumAlpha < 1
      || request.component.foregroundAlpha < 1
      || outlines.contains { $0.1.w < 1 }
    let alphaTexture =
      needsAlpha
      ? try makeTexture(
        pixelFormat: .r8Unorm,
        width: request.pixelWidth,
        height: request.pixelHeight
      )
      : nil

    let glyphs = makeGlyphInstances(for: request)
    guard !glyphs.isEmpty,
      let glyphBuffer = device.makeBuffer(
        bytes: glyphs,
        length: MemoryLayout<GlyphInstance>.stride * glyphs.count,
        options: .storageModeShared
      )
    else {
      throw MetalClockOverlayRendererError.glyphBufferCreationFailed
    }

    let direction = backgroundStyle.direction
    var uniforms = Uniforms(
      foregroundColor: request.component.foregroundColor,
      backgroundColor0: backgroundStyle.color0,
      backgroundColor1: backgroundStyle.color1,
      outlineColor0: outlines.indices.contains(0) ? outlines[0].1 : .zero,
      outlineColor1: outlines.indices.contains(1) ? outlines[1].1 : .zero,
      overlaySize: SIMD2(Float(request.pixelWidth), Float(request.pixelHeight)),
      gradientDirection: direction,
      outlineThickness: SIMD2(
        outlines.indices.contains(0) ? outlines[0].0 : 0,
        outlines.indices.contains(1) ? outlines[1].0 : 0
      ),
      backgroundKind: backgroundStyle.isGradient ? 1 : 0,
      glyphCount: UInt32(glyphs.count)
    )
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
      throw MetalClockOverlayRendererError.commandBufferCreationFailed
    }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = colorTexture
    pass.colorAttachments[0].loadAction = .dontCare
    pass.colorAttachments[0].storeAction = .store
    if let alphaTexture {
      pass.colorAttachments[1].texture = alphaTexture
      pass.colorAttachments[1].loadAction = .dontCare
      pass.colorAttachments[1].storeAction = .store
    }
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
      throw MetalClockOverlayRendererError.renderEncoderCreationFailed
    }
    encoder.label = "Clock Overlay Retained Texture"
    encoder.setRenderPipelineState(alphaTexture == nil ? colorPipeline : colorAlphaPipeline)
    encoder.setFragmentTexture(atlasTexture, index: 0)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
    encoder.setFragmentBuffer(glyphBuffer, offset: 0, index: 1)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.status == .completed else {
      throw MetalClockOverlayRendererError.renderFailed
    }
    return try ClockOverlayTexture(colorTexture: colorTexture, alphaTexture: alphaTexture)
  }

  private func makeTexture(
    pixelFormat: MTLPixelFormat,
    width: Int,
    height: Int
  ) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: pixelFormat,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      throw MetalClockOverlayRendererError.textureCreationFailed
    }
    return texture
  }

  private func makeGlyphInstances(for request: ClockOverlayRenderRequest) -> [GlyphInstance] {
    let lines = request.text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
      line.unicodeScalars.compactMap { scalar -> GlyphMetric? in
        let value = scalar.value
        guard value >= Self.firstCodePoint, value < 0x7f else { return nil }
        return metrics[Int(value - Self.firstCodePoint)]
      }
    }
    guard lines.contains(where: { !$0.isEmpty }) else { return [] }
    let lineCount = max(lines.count, 1)
    let layouts = lines.map { selectedMetrics in
      let unscaledAdvance = selectedMetrics.reduce(Float(0)) { $0 + $1.advance }
      let minY = selectedMetrics.map { $0.offset.y }.min() ?? 0
      let maxY = selectedMetrics.map { $0.offset.y + $0.size.y }.max() ?? 0
      return (
        metrics: selectedMetrics,
        advance: unscaledAdvance,
        minY: minY,
        contentHeight: maxY - minY
      )
    }
    // Treat the destination as a text canvas. Date, time, and their gap form
    // one block with one common font scale, then that block is fitted into the
    // available width and height while preserving a small inset.
    let unscaledInterlineGap = lineCount > 1 ? Self.atlasPixelHeight * 0.12 : 0
    let unscaledBlockHeight =
      layouts.reduce(Float(0)) { $0 + $1.contentHeight }
      + unscaledInterlineGap * Float(max(lineCount - 1, 0))
    let unscaledBlockWidth = layouts.map(\.advance).max() ?? 0
    let widthScale =
      unscaledBlockWidth > 0
      ? Float(request.pixelWidth) * 0.9 / unscaledBlockWidth
      : 1
    let heightScale =
      unscaledBlockHeight > 0
      ? Float(request.pixelHeight) * 0.9 / unscaledBlockHeight
      : 1
    let scale = min(widthScale, heightScale)
    let interlineGap = unscaledInterlineGap * scale
    let blockHeight = unscaledBlockHeight * scale
    var lineTop = (Float(request.pixelHeight) - blockHeight) * 0.5
    var instances: [GlyphInstance] = []
    instances.reserveCapacity(lines.reduce(0) { $0 + $1.count })

    for layout in layouts {
      let baseline = lineTop - layout.minY * scale
      var penX = (Float(request.pixelWidth) - layout.advance * scale) * 0.5
      for metric in layout.metrics {
        if metric.size.x > 0, metric.size.y > 0 {
          let origin = SIMD2<Float>(
            penX + metric.offset.x * scale,
            baseline + metric.offset.y * scale
          )
          let size = metric.size * scale
          instances.append(
            GlyphInstance(
              destinationRect: SIMD4<Float>(
                origin.x, origin.y, origin.x + size.x, origin.y + size.y),
              atlasRect: metric.atlasRect
            ),
          )
        }
        penX += metric.advance * scale
      }
      lineTop += layout.contentHeight * scale + interlineGap
    }
    return instances
  }

  private static func makeAtlas(
    device: MTLDevice,
    fontURL: URL
  ) throws -> (texture: MTLTexture, metrics: [GlyphMetric]) {
    guard let fontData = try? Data(contentsOf: fontURL) else {
      throw MetalClockOverlayRendererError.fontDataUnavailable
    }
    var pixels = [UInt8](repeating: 0, count: atlasWidth * atlasHeight)
    var bakedGlyphs = [LDTXBakedGlyph](repeating: LDTXBakedGlyph(), count: glyphCount)
    let result = fontData.withUnsafeBytes { fontBytes in
      pixels.withUnsafeMutableBufferPointer { pixelsBuffer in
        bakedGlyphs.withUnsafeMutableBufferPointer { glyphsBuffer in
          ldtx_bake_clock_ascii_glyphs(
            fontBytes.bindMemory(to: UInt8.self).baseAddress,
            atlasPixelHeight,
            pixelsBuffer.baseAddress,
            Int32(atlasWidth),
            Int32(atlasHeight),
            glyphsBuffer.baseAddress,
            Int32(glyphCount)
          )
        }
      }
    }
    guard result > 0 else {
      throw MetalClockOverlayRendererError.glyphAtlasCreationFailed
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r8Unorm,
      width: atlasWidth,
      height: atlasHeight,
      mipmapped: false
    )
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      throw MetalClockOverlayRendererError.textureCreationFailed
    }
    pixels.withUnsafeBytes { bytes in
      texture.replace(
        region: MTLRegionMake2D(0, 0, atlasWidth, atlasHeight),
        mipmapLevel: 0,
        withBytes: bytes.baseAddress!,
        bytesPerRow: atlasWidth
      )
    }

    let atlasSize = SIMD2<Float>(Float(atlasWidth), Float(atlasHeight))
    let metrics = bakedGlyphs.map { glyph in
      let origin = SIMD2<Float>(Float(glyph.x0), Float(glyph.y0))
      let end = SIMD2<Float>(Float(glyph.x1), Float(glyph.y1))
      return GlyphMetric(
        atlasRect: SIMD4<Float>(
          origin.x / atlasSize.x,
          origin.y / atlasSize.y,
          end.x / atlasSize.x,
          end.y / atlasSize.y
        ),
        offset: SIMD2<Float>(glyph.x_offset, glyph.y_offset),
        size: end - origin,
        advance: glyph.x_advance
      )
    }
    return (texture, metrics)
  }

  private static func makeShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
    if let library = try? device.makeDefaultLibrary(bundle: .module) {
      return library
    }
    guard
      let sourceURL = Bundle.module.url(
        forResource: "ClockOverlayShaders",
        withExtension: "metal"
      ), let source = try? String(contentsOf: sourceURL, encoding: .utf8)
    else {
      throw MetalClockOverlayRendererError.shaderLibraryUnavailable
    }
    return try device.makeLibrary(source: source, options: nil)
  }
}

extension ClockComponent {
  fileprivate var foregroundColor: SIMD4<Float> {
    SIMD4<Float>(foregroundRed, foregroundGreen, foregroundBlue, foregroundAlpha)
  }
}

private enum ClockBackgroundStyle {
  case solid(SIMD4<Float>)
  case linear(angleDegrees: Float, SIMD4<Float>, SIMD4<Float>)

  var color0: SIMD4<Float> {
    switch self {
    case .solid(let color), .linear(_, let color, _): color
    }
  }

  var color1: SIMD4<Float> {
    switch self {
    case .solid(let color): color
    case .linear(_, _, let color): color
    }
  }

  var isGradient: Bool {
    if case .linear = self { true } else { false }
  }

  var minimumAlpha: Float { min(color0.w, color1.w) }

  var direction: SIMD2<Float> {
    guard case .linear(let degrees, _, _) = self else { return SIMD2(0, 1) }
    let radians = degrees * .pi / 180
    return SIMD2(sin(radians), -cos(radians))
  }

  static func parse(_ source: String) -> Self {
    guard let parsed = ClockCSSBackground.parse(source) else {
      return .solid(.zero)
    }
    switch parsed {
    case .solid(let color):
      return .solid(color.simd)
    case .linearGradient(let degrees, let startColor, let endColor):
      return .linear(angleDegrees: degrees, startColor.simd, endColor.simd)
    }
  }
}

extension ClockCSSColor {
  fileprivate var simd: SIMD4<Float> {
    SIMD4(red, green, blue, alpha)
  }
}
