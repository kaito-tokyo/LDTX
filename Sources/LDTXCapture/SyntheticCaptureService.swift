// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation

public final class SyntheticCaptureService: @unchecked Sendable {
  public typealias SampleHandler = @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void

  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.SyntheticCaptureService")
  private var timer: DispatchSourceTimer?
  private var frameIndex = 0

  public init() {}

  public func start(
    width: Int,
    height: Int,
    frameRate: Int,
    handler: @escaping SampleHandler
  ) throws {
    stop()

    frameIndex = 0

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now(),
      repeating: .nanoseconds(max(1, 1_000_000_000 / max(1, frameRate))),
      leeway: .milliseconds(2)
    )
    timer.setEventHandler { [weak self] in
      self?.emitFrame(
        width: width,
        height: height,
        frameRate: frameRate,
        handler: handler
      )
    }
    self.timer = timer
    timer.resume()
  }

  public func stop() {
    queue.sync {
      timer?.cancel()
      timer = nil
    }
  }

  private func emitFrame(
    width: Int,
    height: Int,
    frameRate: Int,
    handler: SampleHandler
  ) {
    do {
      let videoSampleBuffer = try Self.makeVideoSampleBuffer(
        width: width,
        height: height,
        frameIndex: frameIndex,
        frameRate: frameRate
      )
      handler(videoSampleBuffer, .video)
      frameIndex += 1
    } catch {
      timer?.cancel()
      timer = nil
    }
  }

  public static func makeVideoSampleBuffer(
    width: Int,
    height: Int,
    frameIndex: Int,
    frameRate: Int
  ) throws -> CMSampleBuffer {
    let pixelBuffer = try makePixelBuffer(width: width, height: height, frameIndex: frameIndex)
    let formatDescription = try CMVideoFormatDescription(imageBuffer: pixelBuffer)
    let timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
      presentationTimeStamp: CMTime(
        value: CMTimeValue(frameIndex), timescale: CMTimeScale(frameRate)),
      decodeTimeStamp: .invalid
    )
    return try CMSampleBuffer(
      imageBuffer: pixelBuffer,
      formatDescription: formatDescription,
      sampleTiming: timing
    )
  }

  private static func makePixelBuffer(width: Int, height: Int, frameIndex: Int) throws
    -> CVPixelBuffer
  {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
      &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
      throw SyntheticCaptureServiceError.pixelBufferCreationFailed(status)
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer {
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }

    try fillBiPlanarYUV(pixelBuffer, width: width, height: height, frameIndex: frameIndex)
    return pixelBuffer
  }

  private static func fillBiPlanarYUV(
    _ pixelBuffer: CVPixelBuffer,
    width: Int,
    height: Int,
    frameIndex: Int
  ) throws {
    guard let yBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
      let uvBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
    else {
      throw SyntheticCaptureServiceError.pixelBufferBaseAddressUnavailable
    }

    let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    let yBuffer = yBaseAddress.assumingMemoryBound(to: UInt8.self)
    let uvBuffer = uvBaseAddress.assumingMemoryBound(to: UInt8.self)
    let movingBarX = (frameIndex * 7) % max(1, width)
    let barWidth = max(8, width / 32)
    let barStart = max(0, min(width - 1, movingBarX - barWidth / 2))
    let barLength = min(barWidth, width - barStart)

    for y in 0..<height {
      let row = yBuffer.advanced(by: y * yBytesPerRow)
      let gradient = 48 + (y * 144 / max(1, height - 1))
      let pulse = ((y / max(1, height / 12) + frameIndex / 8) & 1) * 28
      Darwin.memset(row, Int32(min(235, gradient + pulse)), width)
      Darwin.memset(row.advanced(by: barStart), 235, barLength)
    }

    for y in 0..<(height / 2) {
      let row = uvBuffer.advanced(by: y * uvBytesPerRow)
      Darwin.memset(row, 128, width)
      let chromaStart = barStart & ~1
      let chromaLength = min(width - chromaStart, max(2, barLength & ~1))
      if chromaLength > 0 {
        Darwin.memset(
          row.advanced(by: chromaStart), Int32(96 + ((frameIndex / 8) % 64)), chromaLength)
      }
    }
  }

}

public enum SyntheticCaptureServiceError: Error, Equatable, LocalizedError {
  case pixelBufferCreationFailed(CVReturn)
  case pixelBufferBaseAddressUnavailable

  public var errorDescription: String? {
    switch self {
    case .pixelBufferCreationFailed(let status):
      "Synthetic test video pixel buffer creation failed with CVReturn \(status)."
    case .pixelBufferBaseAddressUnavailable:
      "Synthetic test video pixel buffer base address was unavailable."
    }
  }
}
