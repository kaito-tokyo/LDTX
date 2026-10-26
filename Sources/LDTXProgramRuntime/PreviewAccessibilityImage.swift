// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import LDTXWorkspaceAppletInterface
import Metal
import QuartzCore

/// A completed preview render. Storage is immutable and independent of the drawable's lifetime.
public struct PreviewAccessibilityImage: @unchecked Sendable {
  public let image: CGImage

  public init(image: CGImage) { self.image = image }

  /// WebKit's AXImageData dictionary contract, returning tightly packed, straight-alpha sRGB RGBA.
  public func data(for parameters: NSDictionary) -> Data? {
    guard parameters["AXImageDataFormat"] as? String == "RGBA" else { return nil }
    func dimension(_ key: String) -> Int? {
      guard let value = parameters[key] else { return 0 }
      guard let number = value as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
        number.doubleValue >= 0, number.doubleValue <= 16384,
        number.doubleValue.rounded(.towardZero) == number.doubleValue
      else { return nil }
      return number.intValue
    }
    guard let rw = dimension("AXImageDataResizeWidth"),
      let rh = dimension("AXImageDataResizeHeight"),
      let left = dimension("AXImageDataLeft"), let top = dimension("AXImageDataTop"),
      let sw = dimension("AXImageDataWidth"), let sh = dimension("AXImageDataHeight")
    else { return nil }
    var width = rw == 0 ? image.width : rw
    var height = rh == 0 ? image.height : rh
    let limit = 4_000_000
    if width * height > limit {
      let scale = sqrt(Double(limit) / Double(width * height))
      width = max(1, Int(Double(width) * scale))
      height = max(1, Int(Double(height) * scale))
    }
    let cropped = sw > 0 && sh > 0
    let outWidth = cropped ? sw : width
    let outHeight = cropped ? sh : height
    guard outWidth * outHeight <= limit else { return nil }
    var result = Data(count: outWidth * outHeight * 4)
    let success = result.withUnsafeMutableBytes { raw -> Bool in
      guard
        let context = CGContext(
          data: raw.baseAddress, width: outWidth, height: outHeight, bitsPerComponent: 8,
          bytesPerRow: outWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      // CGImage/bitmap storage already has top-first rows. Convert only the crop's
      // top-left coordinates to Quartz's bottom-left drawing coordinates.
      context.interpolationQuality = .high
      context.draw(
        image,
        in: CGRect(
          x: cropped ? -left : 0, y: cropped ? outHeight - height + top : 0,
          width: width, height: height))
      let bytes = raw.bindMemory(to: UInt8.self)
      for offset in stride(from: 0, to: bytes.count, by: 4) {
        let alpha = Int(bytes[offset + 3])
        if alpha > 0 && alpha < 255 {
          for channel in 0..<3 {
            bytes[offset + channel] = UInt8(
              min(255, (Int(bytes[offset + channel]) * 255 + alpha / 2) / alpha))
          }
        }
      }
      return true
    }
    return success ? result : nil
  }
}

/// Keeps one preview drawable alive; GPU readback and conversion run only for AXImageData requests.
public final class PreviewAccessibilityImageStore: PreviewAccessibilityImageReading,
  @unchecked Sendable
{
  private struct Source: @unchecked Sendable {
    let texture: MTLTexture
    let commandQueue: MTLCommandQueue
    // Retaining the drawable prevents its texture from being recycled during an AX read.
    let drawable: CAMetalDrawable?
  }

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.preview-accessibility")
  private var source: Source?
  private var generation = 0

  public init() {}
  public var size: CGSize {
    lock.withLock {
      source.map { CGSize(width: $0.texture.width, height: $0.texture.height) } ?? .zero
    }
  }
  public func data(for parameters: NSDictionary) -> Data? {
    guard parameters["AXImageDataFormat"] as? String == "RGBA" else { return nil }
    let (snapshot, token) = lock.withLock { (source, generation) }
    guard let snapshot else { return nil }
    return queue.sync {
      guard let image = readImage(from: snapshot) else { return nil }
      let data = image.data(for: parameters)
      return lock.withLock { generation == token ? data : nil }
    }
  }
  public func clear() {
    lock.withLock {
      generation += 1
      source = nil
    }
  }

  /// Publish only after committing rendering on this queue. No pixels are read here.
  func update(
    texture: MTLTexture, commandQueue: MTLCommandQueue, drawable: CAMetalDrawable? = nil
  ) {
    let width = texture.width
    let height = texture.height
    guard width > 0, height > 0, width * height <= 16_000_000 else {
      clear()
      return
    }
    lock.withLock {
      source = Source(texture: texture, commandQueue: commandQueue, drawable: drawable)
    }
  }

  private func readImage(from source: Source) -> PreviewAccessibilityImage? {
    let texture = source.texture
    let width = texture.width
    let height = texture.height
    let row = (width * 4 + 255) & ~255
    guard
      let buffer = source.commandQueue.device.makeBuffer(
        length: row * height, options: .storageModeShared),
      let command = source.commandQueue.makeCommandBuffer(),
      let blit = command.makeBlitCommandEncoder()
    else { return nil }
    blit.copy(
      from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
      sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer,
      destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: row * height)
    blit.endEncoding()
    command.commit()
    // Only GPU work on the already-committed render queue is awaited; no UI callback is needed.
    withExtendedLifetime(source.drawable) { command.waitUntilCompleted() }
    guard command.status == .completed else { return nil }
    let data = Data(bytes: buffer.contents(), count: row * height)
    guard let provider = CGDataProvider(data: data as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: row, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: [
          .byteOrder32Little,
          CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
        ],
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    return PreviewAccessibilityImage(image: image)
  }
}
