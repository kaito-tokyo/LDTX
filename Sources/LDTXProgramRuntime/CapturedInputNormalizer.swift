// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import LDTXVideoComposition
import LDTXVideoRendering
import Metal

/// Serialized by the Program renderer. Converts captured inputs before either
/// background removal or composition; capture buffers are never retagged in place.
final class CapturedInputNormalizer {
  enum Failure: Error, LocalizedError {
    case unsupportedFormat(OSType)
    case unsupportedMetadata(String)
    case unavailableColorSpace
    case unavailableFilter
    case inputCopyFailed

    var errorDescription: String? {
      switch self {
      case .unsupportedFormat(let value): "Unsupported captured pixel format: \(value)."
      case .unsupportedMetadata(let key): "Unsupported captured color metadata: \(key)."
      case .unavailableColorSpace: "Core Video could not resolve the captured color space."
      case .unavailableFilter: "Core Image could not create the captured color conversion."
      case .inputCopyFailed: "Could not prepare the captured buffer for color conversion."
      }
    }
  }

  private let device: MTLDevice
  private lazy var context: CIContext = makeContext()
  private let buffers = OutputCanvasResourceManager(minimumBufferCount: 2)
  private let decodingBuffers = OutputCanvasResourceManager(minimumBufferCount: 2)
  private lazy var copyQueue = device.makeCommandQueue()
  private lazy var copyTextureCache: CVMetalTextureCache? = {
    var cache: CVMetalTextureCache?
    guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else {
      return nil
    }
    return cache
  }()
  private let outputColorSpace = CGColorSpace(name: CGColorSpace.coreMedia709)!
  private let canonical: [CFString: CFString] = [
    kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
    kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
    kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
  ]

  init(device: MTLDevice) { self.device = device }

  private func makeContext() -> CIContext {
    CIContext(
      mtlDevice: device,
      options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
      ])
  }

  func normalize(
    _ frame: CapturedVideoFrame, rangeOverride: CameraInputColorRangeOverride = .unspecified
  ) throws -> CapturedVideoFrame {
    let source = frame.pixelBuffer
    let format = CVPixelBufferGetPixelFormatType(source)
    let isNV12 =
      format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    guard
      isNV12 || format == kCVPixelFormatType_32BGRA
        || format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    else {
      throw Failure.unsupportedFormat(format)
    }
    let tags = try colorMetadata(source, isRGB: format == kCVPixelFormatType_32BGRA)
    let hasProfile =
      tags[kCVImageBufferICCProfileKey] != nil || tags[kCVImageBufferCGColorSpaceKey] != nil
    // Preserve both 420v and 420f without allocation, resampling, or GPU work.
    let rangeMatches =
      rangeOverride == .unspecified
      || (rangeOverride == .fullRange && format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
      || (rangeOverride == .videoRange && format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    if isNV12, rangeMatches, !hasProfile,
      canonical.allSatisfy({ CFEqual(tags[$0.key] as CFTypeRef?, $0.value) })
    {
      return frame
    }

    let transfer = tags[kCVImageBufferTransferFunctionKey] as! CFString
    var isPQ = CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
    var isHLG = CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG)
    let is240M = CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_240M_1995) && !hasProfile
    var resolvedTags = tags
    if is240M {
      // Core Video synthesizes 240M with a 709-like TRC on macOS. Import the
      // code values in that base space, then apply the actual 240M→709 curve.
      resolvedTags[kCVImageBufferTransferFunctionKey] = kCVImageBufferTransferFunction_ITU_R_709_2
    }
    let space: CGColorSpace
    if let explicitSpace = tags[kCVImageBufferCGColorSpaceKey] {
      guard CFGetTypeID(explicitSpace as CFTypeRef) == CGColorSpace.typeID else {
        throw Failure.unsupportedMetadata("CGColorSpace")
      }
      space = explicitSpace as! CGColorSpace
    } else {
      guard
        let resolved = CVImageBufferCreateColorSpaceFromAttachments(resolvedTags as CFDictionary)
      else {
        throw Failure.unavailableColorSpace
      }
      space = resolved.takeRetainedValue()
    }
    guard space.model == .rgb else { throw Failure.unavailableColorSpace }
    if hasProfile {
      let profilePQ = CGColorSpaceIsPQBased(space)
      let profileHLG = CGColorSpaceIsHLGBased(space)
      if CVBufferCopyAttachment(source, kCVImageBufferTransferFunctionKey, nil) != nil,
        isPQ != profilePQ || isHLG != profileHLG
      {
        throw Failure.unsupportedMetadata("conflicting HDR profile and transfer tags")
      }
      isPQ = profilePQ
      isHLG = profileHLG
    }
    guard !space.isHDR() || isPQ || isHLG else {
      throw Failure.unsupportedMetadata("HDR profile without a PQ/HLG conversion")
    }
    // YCbCr matrix and range belong to the pixel layout, not its RGB color
    // space. A private copy is needed only to supply a missing matrix or apply
    // a range override. Never retag another view of the capture IOSurface:
    // Core Video shares color attachments between such views on macOS.
    let readFormat: OSType
    switch (format, rangeOverride) {
    case (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, .fullRange):
      readFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    case (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, .videoRange):
      readFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    case (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, .fullRange):
      readFormat = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    case (kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, .videoRange):
      readFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    default: readFormat = format
    }
    let readBuffer: CVPixelBuffer
    if format != kCVPixelFormatType_32BGRA,
      readFormat != format
        || CVBufferCopyAttachment(source, kCVImageBufferYCbCrMatrixKey, nil) == nil
    {
      readBuffer = try decodingBuffer(source, format: readFormat, tags: tags)
    } else {
      readBuffer = source
    }
    var image = CIImage(cvPixelBuffer: readBuffer, options: [.colorSpace: space])
    if is240M {
      let curve = CIFilter.colorCubeWithColorSpace()
      curve.inputImage = image
      curve.cubeDimension = 32
      curve.cubeData = Self.smpte240MCurve
      curve.colorSpace = space
      guard let corrected = curve.outputImage else { throw Failure.unavailableFilter }
      image = corrected
    }
    if isPQ || isHLG {
      // Stable, content-independent SDR mapping: PQ's 10,000-nit code range or
      // nominal 1,000-nit HLG display, relative to 203-nit SDR reference white.
      // Explicit source headroom avoids OS guesses and per-frame exposure pumping.
      let toneMap = CIFilter.toneMapHeadroom()
      toneMap.inputImage = image
      toneMap.sourceHeadroom = isPQ ? 10_000 / 203 : 1_000 / 203
      toneMap.targetHeadroom = 1
      guard let mapped = toneMap.outputImage else { throw Failure.unavailableFilter }
      image = mapped
    }
    let output = try buffers.pixelBuffer(
      for: .init(
        width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source),
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
    // Pool buffers may be reused. Remove stale HDR/profile attachments before
    // assigning the colorimetry of the pixels that Core Image actually produces.
    CVBufferRemoveAllAttachments(output)
    CVBufferSetAttachments(output, canonical as CFDictionary, .shouldPropagate)
    let destination = CIRenderDestination(pixelBuffer: output)
    destination.colorSpace = outputColorSpace
    let task = try context.startTask(toRender: image, to: destination)
    // Neither source nor pooled destination may be released/reused during GPU work,
    // including task failure. No converted frame is published before completion.
    defer { withExtendedLifetime((source, readBuffer, output, image, destination, task)) {} }
    try task.waitUntilCompleted()
    return CapturedVideoFrame(
      pixelBuffer: output,
      sourcePresentationTime: frame.sourcePresentationTime,
      captureSessionID: frame.captureSessionID, sequenceNumber: frame.sequenceNumber)
  }

  private func decodingBuffer(_ source: CVPixelBuffer, format: OSType, tags: [CFString: Any]) throws
    -> CVPixelBuffer
  {
    let copy = try decodingBuffers.pixelBuffer(
      for: .init(
        width: CVPixelBufferGetWidth(source),
        height: CVPixelBufferGetHeight(source), pixelFormat: format))
    guard CVPixelBufferGetPlaneCount(source) == 2, CVPixelBufferGetPlaneCount(copy) == 2 else {
      throw Failure.inputCopyFailed
    }
    let is10Bit =
      format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
      || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    if CVPixelBufferGetIOSurface(source) != nil {
      guard let queue = copyQueue, let cache = copyTextureCache,
        let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
      else {
        throw Failure.inputCopyFailed
      }
      var textures: [CVMetalTexture] = []
      do {
        for plane in 0..<2 {
          let pixelFormat: MTLPixelFormat =
            is10Bit ? (plane == 0 ? .r16Uint : .rg16Uint) : (plane == 0 ? .r8Uint : .rg8Uint)
          for buffer in [source, copy] {
            var texture: CVMetalTexture?
            guard
              CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, buffer, nil, pixelFormat,
                CVPixelBufferGetWidthOfPlane(buffer, plane),
                CVPixelBufferGetHeightOfPlane(buffer, plane),
                plane, &texture) == kCVReturnSuccess, let texture
            else { throw Failure.inputCopyFailed }
            textures.append(texture)
          }
          guard let input = CVMetalTextureGetTexture(textures[plane * 2]),
            let output = CVMetalTextureGetTexture(textures[plane * 2 + 1])
          else { throw Failure.inputCopyFailed }
          blit.copy(from: input, to: output)
        }
      } catch {
        blit.endEncoding()
        throw error
      }
      blit.endEncoding()
      commands.commit()
      commands.waitUntilCompleted()
      withExtendedLifetime((source, copy, textures)) {}
      guard commands.status == .completed else { throw Failure.inputCopyFailed }
    } else {
      // A CPU-backed input has no direct Metal path. Bulk-copy planes without
      // channel shuffling; all color conversion still runs in Core Image.
      guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
        throw Failure.inputCopyFailed
      }
      defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
      guard CVPixelBufferLockBaseAddress(copy, []) == kCVReturnSuccess else {
        throw Failure.inputCopyFailed
      }
      defer { CVPixelBufferUnlockBaseAddress(copy, []) }
      for plane in 0..<2 {
        guard let input = CVPixelBufferGetBaseAddressOfPlane(source, plane),
          let output = CVPixelBufferGetBaseAddressOfPlane(copy, plane)
        else { throw Failure.inputCopyFailed }
        let bytes =
          CVPixelBufferGetWidthOfPlane(source, plane) * (plane == 0 ? 1 : 2) * (is10Bit ? 2 : 1)
        for row in 0..<CVPixelBufferGetHeightOfPlane(source, plane) {
          memcpy(
            output.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(copy, plane)),
            input.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(source, plane)), bytes)
        }
      }
    }
    CVBufferRemoveAllAttachments(copy)
    CVBufferPropagateAttachments(source, copy)
    if let other = CVBufferCopyAttachments(source, .shouldNotPropagate) {
      CVBufferSetAttachments(copy, other, .shouldNotPropagate)
    }
    CVBufferSetAttachments(copy, tags as CFDictionary, .shouldPropagate)
    return copy
  }

  private func colorMetadata(_ buffer: CVPixelBuffer, isRGB: Bool) throws -> [CFString: Any] {
    var result: [CFString: Any] = [:]
    for (key, fallback) in canonical {
      let value =
        CVBufferCopyAttachment(buffer, key, nil)
        ?? (key == kCVImageBufferTransferFunctionKey
          ? (CVBufferCopyAttachment(buffer, kCVImageBufferGammaLevelKey, nil) != nil
            ? kCVImageBufferTransferFunction_UseGamma
            : isRGB ? kCVImageBufferTransferFunction_sRGB : fallback)
          : fallback)
      guard CFGetTypeID(value) == CFStringGetTypeID() else {
        throw Failure.unsupportedMetadata(key as String)
      }
      let string = value as! CFString
      let code: Int32
      switch key {
      case kCVImageBufferColorPrimariesKey:
        code = CVColorPrimariesGetIntegerCodePointForString(string)
      case kCVImageBufferTransferFunctionKey:
        code = CVTransferFunctionGetIntegerCodePointForString(string)
      default: code = CVYCbCrMatrixGetIntegerCodePointForString(string)
      }
      let isGamma =
        key == kCVImageBufferTransferFunctionKey
        && CFEqual(string, kCVImageBufferTransferFunction_UseGamma)
      if isGamma {
        guard
          let gamma = CVBufferCopyAttachment(buffer, kCVImageBufferGammaLevelKey, nil) as? NSNumber,
          gamma.doubleValue.isFinite, gamma.doubleValue > 0
        else {
          throw Failure.unsupportedMetadata("missing or invalid gamma")
        }
      }
      guard code != 2 || isGamma else { throw Failure.unsupportedMetadata("\(key)=\(string)") }
      result[key] = value
    }
    for key in [
      kCVImageBufferCGColorSpaceKey, kCVImageBufferICCProfileKey, kCVImageBufferGammaLevelKey,
    ] {
      result[key] = CVBufferCopyAttachment(buffer, key, nil)
    }
    if CVBufferCopyAttachment(buffer, kCVImageBufferLogTransferFunctionKey, nil) != nil {
      throw Failure.unsupportedMetadata("Apple Log")
    }
    return result
  }

  // One small static separable LUT, evaluated by Apple's GPU filter. All gamut,
  // matrix, range, ICC, sRGB, 2020 and HDR conversions remain platform operations.
  private static let smpte240MCurve: Data = {
    func converted(_ index: Int) -> Float {
      let value = Double(index) / 31
      let linear = value < 0.0912 ? value / 4 : pow((value + 0.1115) / 1.1115, 1 / 0.45)
      return Float(linear < 0.018 ? 4.5 * linear : 1.099 * pow(linear, 0.45) - 0.099)
    }
    var values: [Float] = []
    values.reserveCapacity(32 * 32 * 32 * 4)
    for blue in 0..<32 {
      for green in 0..<32 {
        for red in 0..<32 {
          values += [converted(red), converted(green), converted(blue), 1]
        }
      }
    }
    return values.withUnsafeBytes { Data($0) }
  }()
}
