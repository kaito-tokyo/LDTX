// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Foundation
@_spi(CaptureConversion) import LDTXProgramRuntime
import Metal

struct CapturedPixelBuffer {
  var serial: UInt64
  var pixelBuffer: CVPixelBuffer
}

/// Serializes conversion and publishes owned, immutable buffers. The pool cannot
/// reuse a buffer while a consumer or GPU command still retains it.
final class ProgramRenderCameraFrameStore: @unchecked Sendable {
  private let condition = NSCondition()
  private let normalizer: CapturedInputNormalizer
  private let width: Int
  private let height: Int
  private var capturedPixelBuffer: CapturedPixelBuffer?
  private var conversionError: (any Error)?
  private var latestSerial: UInt64 = 0

  init(width: Int, height: Int, device: MTLDevice) {
    self.width = width
    self.height = height
    normalizer = CapturedInputNormalizer(device: device)
  }

  func wait(after serial: UInt64? = nil, timeout: TimeInterval) throws -> CapturedPixelBuffer? {
    let deadline = Date(timeIntervalSinceNow: timeout)
    condition.lock()
    defer { condition.unlock() }
    while capturedPixelBuffer == nil || (serial != nil && capturedPixelBuffer!.serial <= serial!) {
      if let conversionError { throw conversionError }
      guard condition.wait(until: deadline) else { return nil }
    }
    return capturedPixelBuffer
  }

  func copyAndYield(_ sourcePixelBuffer: CVPixelBuffer) {
    condition.lock()
    defer { condition.unlock() }
    do {
      let owned = try normalizer.normalize(
        pixelBuffer: sourcePixelBuffer, width: width, height: height)
      latestSerial &+= 1
      capturedPixelBuffer = CapturedPixelBuffer(serial: latestSerial, pixelBuffer: owned)
      conversionError = nil
    } catch {
      conversionError = error
    }
    condition.broadcast()
  }
}
