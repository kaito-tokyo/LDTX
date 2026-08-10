// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import CoreImage
import CoreVideo
import Foundation
import os

public final class VisionFrameSnapshot: @unchecked Sendable {
  public var pixelBuffer: CVPixelBuffer { box.value }
  public var image: CIImage { CIImage(cvPixelBuffer: pixelBuffer) }

  private let box: VisionPixelBufferBox
  private let releaseBuffer: @Sendable (VisionPixelBufferBox) -> Void

  fileprivate init(
    box: VisionPixelBufferBox, releaseBuffer: @escaping @Sendable (VisionPixelBufferBox) -> Void
  ) {
    self.box = box
    self.releaseBuffer = releaseBuffer
  }

  deinit { releaseBuffer(box) }
}

private final class VisionPixelBufferBox: @unchecked Sendable {
  let value: CVPixelBuffer
  init(_ value: CVPixelBuffer) { self.value = value }
}

/// A small fixed-envelope pool for the 16:9 VLM input snapshot.
public final class VisionFramePool: @unchecked Sendable {
  public static let width = 512
  public static let height = 288

  private let lock = OSAllocatedUnfairLock(initialState: [VisionPixelBufferBox]())
  private let context = CIContext(options: [.cacheIntermediates: false])
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

  public init(capacity: Int = 2) {
    let buffers = (0..<max(capacity, 1)).compactMap { _ in
      Self.makeBuffer().map(VisionPixelBufferBox.init)
    }
    lock.withLock { $0 = buffers }
  }

  public func copy(image: CIImage) -> VisionFrameSnapshot? {
    guard !image.extent.isEmpty else { return nil }
    guard let buffer = lock.withLock({ $0.popLast() }) else { return nil }
    let bounds = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
    let sx = bounds.width / image.extent.width
    let sy = bounds.height / image.extent.height
    let rendered =
      image
      .transformed(
        by: CGAffineTransform(
          translationX: -image.extent.minX,
          y: -image.extent.minY
        )
      )
      .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    context.render(rendered, to: buffer.value, bounds: bounds, colorSpace: colorSpace)
    return VisionFrameSnapshot(box: buffer) { [weak self] returned in
      self?.lock.withLock { $0.append(returned) }
    }
  }

  private static func makeBuffer() -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attributes: CFDictionary =
      [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
      ] as CFDictionary
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        == kCVReturnSuccess
    else { return nil }
    return buffer
  }
}

/// A single-slot, resolution-preserving copier for OCR input.
public final class VisionOCRFrameCopier: @unchecked Sendable {
  private let isAvailable = OSAllocatedUnfairLock(initialState: true)
  private let context = CIContext(options: [.cacheIntermediates: false])
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

  public init() {}

  public func copy(image: CIImage, subsamplingRate: Int) -> VisionFrameSnapshot? {
    guard !image.extent.isEmpty else { return nil }
    guard
      isAvailable.withLock({ available in
        guard available else { return false }
        available = false
        return true
      })
    else { return nil }
    let rate = [1, 2, 4].contains(subsamplingRate) ? subsamplingRate : 2
    let width = max(Int(image.extent.width.rounded(.down)) / rate, 1)
    let height = max(Int(image.extent.height.rounded(.down)) / rate, 1)
    var pixelBuffer: CVPixelBuffer?
    let attributes: CFDictionary =
      [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
      ] as CFDictionary
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer
      ) == kCVReturnSuccess, let pixelBuffer
    else {
      isAvailable.withLock { $0 = true }
      return nil
    }
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let rendered =
      image
      .transformed(
        by: CGAffineTransform(
          translationX: -image.extent.minX,
          y: -image.extent.minY
        )
      )
      .transformed(
        by: CGAffineTransform(
          scaleX: CGFloat(width) / image.extent.width,
          y: CGFloat(height) / image.extent.height
        ))
    context.render(rendered, to: pixelBuffer, bounds: bounds, colorSpace: colorSpace)
    return VisionFrameSnapshot(box: VisionPixelBufferBox(pixelBuffer)) { [weak self] _ in
      self?.isAvailable.withLock { $0 = true }
    }
  }
}
