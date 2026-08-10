// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Foundation

public enum OutputCanvasResourceManagerError: Error, LocalizedError {
  case invalidPixelBufferRequest(OutputCanvasResourceManager.PixelBufferRequest)
  case pixelBufferPoolCreationFailed(OutputCanvasResourceManager.PixelBufferRequest, CVReturn)
  case pixelBufferCreationFailed(OutputCanvasResourceManager.PixelBufferRequest, CVReturn)

  public var errorDescription: String? {
    switch self {
    case .invalidPixelBufferRequest(let request):
      "The output canvas pixel buffer request is invalid: \(Self.describe(request))."
    case .pixelBufferPoolCreationFailed(let request, let status):
      "CVPixelBufferPoolCreate failed with status \(status): \(Self.describe(request))."
    case .pixelBufferCreationFailed(let request, let status):
      "CVPixelBufferPoolCreatePixelBuffer failed with status \(status): \(Self.describe(request))."
    }
  }

  private static func describe(_ request: OutputCanvasResourceManager.PixelBufferRequest) -> String
  {
    "\(request.width)x\(request.height)/\(fourCC(request.pixelFormat))"
  }

  private static func fourCC(_ value: OSType) -> String {
    let scalars = [
      UnicodeScalar((value >> 24) & 0xff),
      UnicodeScalar((value >> 16) & 0xff),
      UnicodeScalar((value >> 8) & 0xff),
      UnicodeScalar(value & 0xff),
    ]
    let string = scalars.compactMap { $0 }.map(String.init).joined()
    return string.isEmpty ? "\(value)" : "\(string)(\(value))"
  }
}

public final class OutputCanvasResourceManager: @unchecked Sendable {
  public struct PixelBufferRequest: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var pixelFormat: OSType

    public init(width: Int, height: Int, pixelFormat: OSType) {
      self.width = max(width, 1)
      self.height = max(height, 1)
      self.pixelFormat = pixelFormat
    }
  }

  private let minimumBufferCount: Int
  private let lock = NSLock()
  private var pixelBufferPools: [PixelBufferRequest: CVPixelBufferPool] = [:]

  public init(minimumBufferCount: Int = 24) {
    self.minimumBufferCount = max(minimumBufferCount, 1)
  }

  public func pixelBuffer(for request: PixelBufferRequest) throws -> CVPixelBuffer {
    let pool = try pixelBufferPool(for: request)
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
    guard status == kCVReturnSuccess, let pixelBuffer else {
      throw OutputCanvasResourceManagerError.pixelBufferCreationFailed(request, status)
    }
    return pixelBuffer
  }

  private func pixelBufferPool(for request: PixelBufferRequest) throws -> CVPixelBufferPool {
    guard request.width > 0,
      request.height > 0
    else {
      throw OutputCanvasResourceManagerError.invalidPixelBufferRequest(request)
    }

    lock.lock()
    if let pixelBufferPool = pixelBufferPools[request] {
      lock.unlock()
      return pixelBufferPool
    }
    lock.unlock()

    let pixelBufferPool = try makePixelBufferPool(for: request)

    lock.lock()
    if let existingPixelBufferPool = pixelBufferPools[request] {
      lock.unlock()
      return existingPixelBufferPool
    }
    pixelBufferPools[request] = pixelBufferPool
    lock.unlock()
    return pixelBufferPool
  }

  private func makePixelBufferPool(for request: PixelBufferRequest) throws -> CVPixelBufferPool {
    let poolAttributes: [String: Any] = [
      kCVPixelBufferPoolMinimumBufferCountKey as String: minimumBufferCount
    ]
    let pixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: request.pixelFormat,
      kCVPixelBufferWidthKey as String: request.width,
      kCVPixelBufferHeightKey as String: request.height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    var pixelBufferPool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(
      kCFAllocatorDefault,
      poolAttributes as CFDictionary,
      pixelBufferAttributes as CFDictionary,
      &pixelBufferPool
    )
    guard status == kCVReturnSuccess, let pixelBufferPool else {
      throw OutputCanvasResourceManagerError.pixelBufferPoolCreationFailed(request, status)
    }
    return pixelBufferPool
  }
}
