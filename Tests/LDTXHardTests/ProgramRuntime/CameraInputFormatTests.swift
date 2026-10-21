// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreVideo
@testable import LDTXCapture
@testable import LDTXProgramRuntime
import LDTXVideoComposition
@testable import LDTXVideoRendering
import Metal
import Testing

@Suite struct CameraInputFormatIntegrationTestSuite {
  @Test func capturePreferenceFallsBackOnlyToSupportedAdapters() {
    let video = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    let bgra = kCVPixelFormatType_32BGRA
    #expect(CaptureSessionManager.preferredVideoPixelFormat(from: [bgra, full, video]) == video)
    #expect(CaptureSessionManager.preferredVideoPixelFormat(from: [bgra, full]) == full)
    #expect(CaptureSessionManager.preferredVideoPixelFormat(from: [bgra]) == bgra)
    #expect(
      CaptureSessionManager.preferredVideoPixelFormat(from: [kCVPixelFormatType_32ARGB]) == nil)
    #expect(CaptureSessionManager.preferredVideoPixelFormat(from: []) == nil)
  }

  @Test(arguments: [false, true]) func nv12RangeHasNumericallyCorrectEndpointsAndColor(video: Bool)
    throws
  {
    let context = try Context()
    let format =
      video
      ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    for (sample, expected) in [
      ([16, 128, 128], video ? [0, 128, 128] : [16, 128, 128]),
      ([235, 128, 128], video ? [255, 128, 128] : [235, 128, 128]),
      ([81, 90, 240], video ? [75, 85, 255] : [81, 90, 240]),
    ] {
      let buffer = try context.buffer(format)
      CVPixelBufferLockBaseAddress(buffer, [])
      for plane in 0..<2 {
        let address = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
          .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
          for column in 0..<4 {
            address[row * stride + column] = UInt8(sample[plane == 0 ? 0 : 1 + column % 2])
          }
        }
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      let output = try context.render(buffer)
      let actual = try context.values(output)
      for (a, e) in zip(actual, expected) { #expect(abs(a - e) <= 1) }
    }
  }

  @Test(arguments: [0, 1, 2, 3, 4]) func bgraConvertsToFullRange709WithoutChannelSwap(color: Int)
    throws
  {
    let context = try Context()
    let rgb = [[0, 0, 0], [255, 255, 255], [255, 0, 0], [0, 255, 0], [0, 0, 255]][color]
    let expected = [
      [0, 128, 128], [255, 128, 128], [54, 98, 255], [182, 29, 12], [18, 255, 116],
    ][color]
    let buffer = try context.bgra(rgb)
    let output = try context.render(buffer)
    let actual = try context.values(output)
    for (a, e) in zip(actual, expected) { #expect(abs(a - e) <= 1) }
  }

  @Test func bgraPreservesFrameIdentityAndMetadata() throws {
    let context = try Context()
    let buffer = try context.bgra([255, 0, 0])
    let frame = CapturedVideoFrame(
      pixelBuffer: buffer, sourcePresentationTime: CMTime(value: 41, timescale: 30),
      captureSessionID: UUID(), sequenceNumber: 19)
    let normalized = try context.normalizer.normalize(frame)
    let prepared = PreparedVideoInput(frame: normalized)
    let source = try VideoInputMetalTextures(
      pixelBuffer: normalized.pixelBuffer, textureCache: context.cache
    ).makeSource(from: prepared)
    guard case .nv12Textures(let retained, _, _, _, _, let kind) = source else {
      Issue.record("Expected normalized NV12 source")
      return
    }
    #expect(retained !== buffer)
    #expect(
      CVPixelBufferGetPixelFormatType(retained) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    #expect(kind == .captured)
    #expect(normalized.captureSessionID == frame.captureSessionID)
    #expect(normalized.sourcePresentationTime == frame.sourcePresentationTime)
    #expect(normalized.sequenceNumber == 19)
  }

  @Test func unsupportedPackedFormatIsRejectedAtInputBoundary() throws {
    let context = try Context()
    let buffer = try context.buffer(kCVPixelFormatType_32ARGB)
    #expect(throws: VideoCompositorError.self) {
      try VideoInputMetalTextures(pixelBuffer: buffer, textureCache: context.cache)
    }
  }

  @Test func explicitUnsupportedColorMetadataIsRejectedAndNextRenderRecovers() throws {
    let context = try Context()
    let buffer = try context.bgra([255, 0, 0], iosurface: false)
    CVBufferSetAttachment(
      buffer, kCVImageBufferColorPrimariesKey, "unknown-primaries" as CFString, .shouldPropagate
    )
    #expect(throws: CapturedInputNormalizer.Failure.self) { try context.render(buffer) }
    CVBufferRemoveAttachment(buffer, kCVImageBufferColorPrimariesKey)
    let result = try context.values(context.render(buffer))
    for (a, e) in zip(result, [54, 98, 255]) { #expect(abs(a - e) <= 1) }
  }

  @Test(arguments: [false, true]) func bgraSupportsForegroundMasks(raw: Bool) throws {
    let context = try Context()
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: raw ? .r16Float : .r8Uint, width: 4, height: 4, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    let mask = try #require(context.device.makeTexture(descriptor: descriptor))
    if raw {
      let values = [Float16](repeating: 0.5, count: 16)
      values.withUnsafeBytes {
        mask.replace(
          region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: $0.baseAddress!,
          bytesPerRow: 8)
      }
    } else {
      let values = [UInt8](repeating: 128, count: 16)
      values.withUnsafeBytes {
        mask.replace(
          region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: $0.baseAddress!,
          bytesPerRow: 4)
      }
    }
    let output = try context.render(context.bgra([255, 0, 0]), mask: mask, raw: raw)
    #expect(try context.values(output) == [27, 113, 192])
  }

  @Test func bgraCropAndReversedAxesUseActualInputDimensions() throws {
    let context = try Context()
    let buffer = try context.bgra([255, 0, 0])
    CVPixelBufferLockBaseAddress(buffer, [])
    let address = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(
      to: UInt8.self)
    // Left half red, right half blue. Crop only the right half, reversed.
    for y in 0..<4 {
      for x in 2..<4 {
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        address[offset] = 255
        address[offset + 2] = 0
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let output = try context.render(buffer, sourceRect: SIMD4(1, 1, -0.5, -1))
    // The center of the crop remains blue despite both reversed axes.
    #expect(try context.values(output, x: 1, y: 1)[0] == 18)
  }

  @Test(arguments: [false, true]) func inputBuffersAreReleasedAfterSuccessAndEncodingFailure(
    fail: Bool
  ) throws {
    let context = try Context()
    weak var releasedBuffer: CVPixelBuffer?
    try autoreleasepool {
      let buffer = try context.bgra([255, 0, 0], iosurface: !fail)
      releasedBuffer = buffer
      if fail {
        CVBufferSetAttachment(
          buffer, kCVImageBufferColorPrimariesKey, "unknown-primaries" as CFString,
          .shouldPropagate)
        #expect(throws: CapturedInputNormalizer.Failure.self) { try context.render(buffer) }
      } else {
        let result = try context.values(context.render(buffer))
        for (a, e) in zip(result, [54, 98, 255]) { #expect(abs(a - e) <= 1) }
      }
    }
    CVMetalTextureCacheFlush(context.cache, 0)
    #expect(releasedBuffer == nil)
  }

  private struct Context {
    let device: MTLDevice
    let cache: CVMetalTextureCache
    let compositor: VideoCompositor
    let normalizer: CapturedInputNormalizer
    init() throws {
      device = try #require(MTLCreateSystemDefaultDevice())
      normalizer = CapturedInputNormalizer(device: device)
      var optional: CVMetalTextureCache?
      try #require(CVMetalTextureCacheCreate(nil, nil, device, nil, &optional) == kCVReturnSuccess)
      cache = try #require(optional)
      compositor = try VideoCompositor(
        configuration: .init(width: 4, height: 4, pixelBufferPoolMinimumBufferCount: 1),
        device: device)
    }
    func buffer(_ format: OSType, iosurface: Bool = true) throws -> CVPixelBuffer {
      var optional: CVPixelBuffer?
      try #require(
        CVPixelBufferCreate(
          nil, 4, 4, format,
          (iosurface
            ? [
              kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
            ] : [:])
            as CFDictionary, &optional) == kCVReturnSuccess)
      return try #require(optional)
    }
    func bgra(_ rgb: [Int], iosurface: Bool = true) throws -> CVPixelBuffer {
      let buffer = try buffer(kCVPixelFormatType_32BGRA, iosurface: iosurface)
      CVPixelBufferLockBaseAddress(buffer, [])
      let address = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(
        to: UInt8.self)
      for y in 0..<4 {
        for x in 0..<4 {
          let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
          for (channel, value) in [rgb[2], rgb[1], rgb[0], 255].enumerated() {
            address[offset + channel] = UInt8(value)
          }
        }
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      return buffer
    }
    func render(
      _ buffer: CVPixelBuffer, mask: MTLTexture? = nil, raw: Bool = false,
      sourceRect: SIMD4<Float> = SIMD4(0, 0, 1, 1)
    ) throws -> CVPixelBuffer {
      let frame = CapturedVideoFrame(
        pixelBuffer: buffer, sourcePresentationTime: .zero, captureSessionID: UUID(),
        sequenceNumber: 1)
      let normalized = try normalizer.normalize(frame)
      let input = PreparedVideoInput(
        frame: normalized, alphaTexture: mask,
        alphaMaskKind: mask == nil ? nil : raw ? .rawFloat16 : .oneComponent8)
      let source = try VideoInputMetalTextures(
        pixelBuffer: normalized.pixelBuffer, textureCache: cache
      ).makeSource(
        from: input)
      return try compositor.render([
        CameraInputComponent(
          source: source, destinationRect: SIMD4(0, 0, 4, 4), sourceRect: sourceRect)
      ])
    }
    func values(_ buffer: CVPixelBuffer, x: Int = 0, y row: Int = 0) throws -> [Int] {
      CVPixelBufferLockBaseAddress(buffer, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
      let y = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(
        to: UInt8.self)
      let uv = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(
        to: UInt8.self)
      return [
        Int(y[row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + x]),
        Int(uv[(row / 2) * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + (x / 2) * 2]),
        Int(uv[(row / 2) * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + (x / 2) * 2 + 1]),
      ]
    }
  }
}
