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
    var backgroundColor: SIMD4<Float>
    var glyphCount: UInt32
    var padding = SIMD3<UInt32>(repeating: 0)
  }

  private static let firstCodePoint: UInt32 = 0x20
  private static let glyphCount = 0x7f - Int(firstCodePoint)
  private static let atlasWidth = 1_024
  private static let atlasHeight = 512
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
    let needsAlpha = request.component.backgroundAlpha < 1
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

    var uniforms = Uniforms(
      foregroundColor: request.component.foregroundColor,
      backgroundColor: request.component.backgroundColor,
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
    let scalars = request.text.unicodeScalars.compactMap { scalar -> UInt32? in
      let value = scalar.value
      return value >= Self.firstCodePoint && value < 0x7f ? value : nil
    }
    let selectedMetrics = scalars.map { metrics[Int($0 - Self.firstCodePoint)] }
    guard !selectedMetrics.isEmpty else { return [] }

    let unscaledAdvance = selectedMetrics.reduce(Float(0)) { $0 + $1.advance }
    let baseScale = Float(request.pixelHeight) * 0.62 / Self.atlasPixelHeight
    let widthScale =
      unscaledAdvance > 0
      ? Float(request.pixelWidth) * 0.9 / unscaledAdvance
      : baseScale
    let scale = min(baseScale, widthScale)
    let minY = selectedMetrics.map { $0.offset.y }.min() ?? 0
    let maxY = selectedMetrics.map { $0.offset.y + $0.size.y }.max() ?? 0
    let contentHeight = (maxY - minY) * scale
    let baseline = (Float(request.pixelHeight) - contentHeight) * 0.5 - minY * scale
    var penX = (Float(request.pixelWidth) - unscaledAdvance * scale) * 0.5
    var instances: [GlyphInstance] = []
    instances.reserveCapacity(selectedMetrics.count)

    for metric in selectedMetrics {
      if metric.size.x > 0, metric.size.y > 0 {
        let origin = SIMD2<Float>(
          penX + metric.offset.x * scale,
          baseline + metric.offset.y * scale
        )
        let size = metric.size * scale
        instances.append(
          GlyphInstance(
            destinationRect: SIMD4<Float>(
              origin.x,
              origin.y,
              origin.x + size.x,
              origin.y + size.y
            ),
            atlasRect: metric.atlasRect
          ))
      }
      penX += metric.advance * scale
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

  fileprivate var backgroundColor: SIMD4<Float> {
    SIMD4<Float>(backgroundRed, backgroundGreen, backgroundBlue, backgroundAlpha)
  }
}
