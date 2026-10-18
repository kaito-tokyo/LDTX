// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreText
import Foundation
import LDTXFontRasterizer
import LDTXProgram
import LDTXRichText
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
      "The overlay dimensions are invalid or exceed the raster pixel budget. Reduce the layer size or scale."
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
    var outlineColor0: SIMD4<Float>
    var outlineColor1: SIMD4<Float>
    var outlineThickness: SIMD2<Float>
    var glyphCount: UInt32
  }

  private static let firstCodePoint: UInt32 = 0x20
  private static let glyphCount = 0x7f - Int(firstCodePoint)
  private static let atlasWidth = 2_048
  private static let atlasHeight = 1_024
  private static let atlasPixelHeight: Float = 96
  // RGBA, RGB565, alpha staging and both textures total 10 bytes per pixel.
  // Bound these allocations to 80 MiB per render, including a full 4K UHD frame.
  private static let dynamicTextPixelBudget = 8_388_608

  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let atlasTexture: MTLTexture
  private let metrics: [GlyphMetric]
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
      let colorAlphaFragment = library.makeFunction(name: "clockOverlayColorAlphaFragment")
    else {
      throw MetalClockOverlayRendererError.shaderFunctionUnavailable
    }

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

    if request.component.resolvedRTFD != nil {
      return try renderDynamicText(request)
    }

    let colorTexture = try makeTexture(
      pixelFormat: .b5g6r5Unorm,
      width: request.pixelWidth,
      height: request.pixelHeight
    )
    let outlines = request.component.outlines.prefix(2).map {
      (
        max($0.thickness, 0),
        ClockOutlineColor.parse($0.color)?.simd ?? SIMD4<Float>(0, 0, 0, 1)
      )
    }
    let alphaTexture = try makeTexture(
      pixelFormat: .r8Unorm, width: request.pixelWidth, height: request.pixelHeight)

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

    var uniforms = Uniforms(
      foregroundColor: request.component.foregroundColor,
      outlineColor0: outlines.indices.contains(0) ? outlines[0].1 : .zero,
      outlineColor1: outlines.indices.contains(1) ? outlines[1].1 : .zero,
      outlineThickness: SIMD2(
        outlines.indices.contains(0) ? outlines[0].0 : 0,
        outlines.indices.contains(1) ? outlines[1].0 : 0
      ),
      glyphCount: UInt32(glyphs.count)
    )
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
      throw MetalClockOverlayRendererError.commandBufferCreationFailed
    }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = colorTexture
    pass.colorAttachments[0].loadAction = .dontCare
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[1].texture = alphaTexture
    pass.colorAttachments[1].loadAction = .dontCare
    pass.colorAttachments[1].storeAction = .store
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
      throw MetalClockOverlayRendererError.renderEncoderCreationFailed
    }
    encoder.label = "Clock Overlay Retained Texture"
    encoder.setRenderPipelineState(colorAlphaPipeline)
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

  /// Core Text provides Unicode shaping and system font fallback on the overlay worker queue.
  private func renderDynamicText(_ request: ClockOverlayRenderRequest) throws -> ClockOverlayTexture
  {
    let width = request.pixelWidth
    let height = request.pixelHeight
    guard width <= Self.dynamicTextPixelBudget / height else {
      throw MetalClockOverlayRendererError.invalidTextureSize
    }
    let component = request.component
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
      guard
        let context = CGContext(
          data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      guard let data = component.resolvedRTFD,
        let document = try? LDTXRichTextDocument(rtfd: data),
        let original = try? document.attributedString()
      else { return false }
      let string = NSMutableAttributedString(attributedString: original)
      original.enumerateAttributes(in: NSRange(location: 0, length: original.length)) {
        attributes, range, _ in
        if let font = attributes[.font] as? NSFont {
          string.addAttribute(
            NSAttributedString.Key(kCTFontAttributeName as String),
            value: CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil),
            range: range)
        }
        if let color = attributes[.foregroundColor] as? NSColor {
          string.addAttribute(
            NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: color.cgColor,
            range: range)
        }
      }
      context.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
      let framesetter = CTFramesetterCreateWithAttributedString(string)
      let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
      CTFrameDraw(
        CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), context)
      return true
    }
    guard rendered else { throw MetalClockOverlayRendererError.textureCreationFailed }
    var rgb565 = [UInt16](repeating: 0, count: width * height)
    var alpha = [UInt8](repeating: 0, count: width * height)
    for index in alpha.indices {
      // Core Graphics bitmap rows already match the texture's top-down storage.
      let source = index * 4
      let a = UInt32(rgba[source + 3])
      alpha[index] = UInt8(a)
      if a > 0 {
        let r = UInt32(rgba[source]) * 255 / a
        let g = UInt32(rgba[source + 1]) * 255 / a
        let b = UInt32(rgba[source + 2]) * 255 / a
        rgb565[index] = UInt16((r >> 3) << 11 | (g >> 2) << 5 | (b >> 3))
      }
    }
    func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: format, width: width, height: height, mipmapped: false)
      descriptor.storageMode = .shared
      descriptor.usage = .shaderRead
      guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw MetalClockOverlayRendererError.textureCreationFailed
      }
      return texture
    }
    let colorTexture = try texture(.b5g6r5Unorm)
    let alphaTexture = try texture(.r8Unorm)
    let region = MTLRegionMake2D(0, 0, width, height)
    rgb565.withUnsafeBytes {
      colorTexture.replace(
        region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 2)
    }
    alpha.withUnsafeBytes {
      alphaTexture.replace(
        region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width)
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

  /// Reserve enough room for every formatted digit, avoiding a size change on each tick.
  /// This uses the same bundled-font atlas metrics as glyph rendering, on the producer queue.
  func naturalClockSize(for component: ClockComponent) -> SIMD2<Float>? {
    guard let fontSize = component.fontSize, fontSize.isFinite, fontSize > 0 else { return nil }
    func metric(_ character: Character) -> GlyphMetric {
      metrics[Int(character.asciiValue! - UInt8(Self.firstCodePoint))]
    }
    let widestDigit = "0123456789".max { metric($0).advance < metric($1).advance }!
    let date =
      String(repeating: widestDigit, count: 4) + "/" + String(repeating: widestDigit, count: 2)
      + "/" + String(repeating: widestDigit, count: 2)
    let time =
      String(repeating: widestDigit, count: 2) + ":" + String(repeating: widestDigit, count: 2)
      + (component.showsSeconds ? ":" + String(repeating: widestDigit, count: 2) : "")
    let timeWidth =
      time.reduce(Float(0)) { $0 + metric($1).advance }
      + (component.uses24HourTime
        ? 0
        : max(
          " AM".reduce(Float(0)) { $0 + metric($1).advance },
          " PM".reduce(Float(0)) { $0 + metric($1).advance }))
    let width =
      component.showsDate
      ? max(timeWidth, date.reduce(Float(0)) { $0 + metric($1).advance }) : timeWidth
    let glyphs = "0123456789/: APM".map(metric)
    let lineHeight =
      (glyphs.map { $0.offset.y + $0.size.y }.max() ?? 0)
      - (glyphs.map { $0.offset.y }.min() ?? 0)
    let height = component.showsDate ? lineHeight * 2 + Self.atlasPixelHeight * 0.12 : lineHeight
    let padding = 4 + component.outlines.prefix(2).reduce(Float(0)) { $0 + max($1.thickness, 0) }
    let size = SIMD2(
      ceil(width * fontSize / Self.atlasPixelHeight + padding * 2),
      ceil(height * fontSize / Self.atlasPixelHeight + padding * 2))
    guard size.x.isFinite, size.y.isFinite, size.x <= 16384, size.y <= 16384,
      size.x * size.y <= Float(Self.dynamicTextPixelBudget)
    else { return nil }
    return size
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
    let natural = naturalClockSize(for: request.component)
    let horizontalScale =
      natural.map {
        request.component.fontSize! / Self.atlasPixelHeight
          * Float(request.pixelWidth) / $0.x
      } ?? scale
    let verticalScale =
      natural.map {
        request.component.fontSize! / Self.atlasPixelHeight
          * Float(request.pixelHeight) / $0.y
      } ?? scale
    let interlineGap = unscaledInterlineGap * verticalScale
    let blockHeight = unscaledBlockHeight * verticalScale
    var lineTop = (Float(request.pixelHeight) - blockHeight) * 0.5
    var instances: [GlyphInstance] = []
    instances.reserveCapacity(lines.reduce(0) { $0 + $1.count })

    for layout in layouts {
      let baseline = lineTop - layout.minY * verticalScale
      var penX = (Float(request.pixelWidth) - layout.advance * horizontalScale) * 0.5
      for metric in layout.metrics {
        if metric.size.x > 0, metric.size.y > 0 {
          let origin = SIMD2<Float>(
            penX + metric.offset.x * horizontalScale,
            baseline + metric.offset.y * verticalScale
          )
          let size = metric.size * SIMD2(horizontalScale, verticalScale)
          instances.append(
            GlyphInstance(
              destinationRect: SIMD4<Float>(
                origin.x, origin.y, origin.x + size.x, origin.y + size.y),
              atlasRect: metric.atlasRect
            ),
          )
        }
        penX += metric.advance * horizontalScale
      }
      lineTop += layout.contentHeight * verticalScale + interlineGap
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
    if let library = try? device.makeDefaultLibrary(bundle: ldtxProgramRuntimeBundle) {
      return library
    }
    guard
      let sourceURL = ldtxProgramRuntimeBundle.url(
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

extension ClockOutlineColor {
  fileprivate var simd: SIMD4<Float> {
    SIMD4(red, green, blue, alpha)
  }
}
