// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Darwin
import Foundation

public final class SyntheticCaptureService: @unchecked Sendable {
  public typealias SampleHandler = @Sendable (CMSampleBuffer, CameraCaptureSampleKind) -> Void

  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.SyntheticCaptureService")
  private var timer: DispatchSourceTimer?
  private var frameIndex = 0
  private var nextAudioSampleIndex = 0

  public init() {}

  public func start(
    width: Int,
    height: Int,
    frameRate: Int,
    audioSampleRate: Int = 48_000,
    audioChannelCount: Int = 2,
    handler: @escaping SampleHandler
  ) throws {
    stop()

    frameIndex = 0
    nextAudioSampleIndex = 0

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
        audioSampleRate: audioSampleRate,
        audioChannelCount: audioChannelCount,
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
    audioSampleRate: Int,
    audioChannelCount: Int,
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

      let videoEndTime = CMTime(
        value: CMTimeValue(frameIndex + 1),
        timescale: CMTimeScale(frameRate)
      )
      while CMTime(
        value: CMTimeValue(nextAudioSampleIndex),
        timescale: CMTimeScale(audioSampleRate)
      ) < videoEndTime {
        let sampleCount = 1_024
        let audioSampleBuffer = try Self.makeAudioSampleBuffer(
          sampleRate: audioSampleRate,
          channelCount: audioChannelCount,
          startSampleIndex: nextAudioSampleIndex,
          sampleCount: sampleCount
        )
        handler(audioSampleBuffer, .audio)
        nextAudioSampleIndex += sampleCount
      }

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

  public static func makeAudioSampleBuffer(
    sampleRate: Int,
    channelCount: Int,
    startSampleIndex: Int,
    sampleCount: Int
  ) throws -> CMSampleBuffer {
    let bytesPerSample = MemoryLayout<Int16>.size
    let bytesPerFrame = bytesPerSample * channelCount
    var data = Data(count: sampleCount * bytesPerFrame)
    data.withUnsafeMutableBytes { rawBuffer in
      let samples = rawBuffer.bindMemory(to: Int16.self)
      for frame in 0..<sampleCount {
        let absoluteSample = startSampleIndex + frame
        for channel in 0..<channelCount {
          let frequency = channel == 0 ? 440 : 660
          let period = max(1, sampleRate / frequency)
          let phase = absoluteSample % period
          let ramp = phase < period / 2 ? phase : period - phase
          let normalized = (ramp * 4 * 12_000 / period) - 12_000
          samples[frame * channelCount + channel] = Int16(normalized)
        }
      }
    }

    var blockBuffer: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: data.count,
      blockAllocator: nil,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: data.count,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
      throw SyntheticCaptureServiceError.blockBufferCreationFailed(blockStatus)
    }
    try data.withUnsafeBytes { rawBuffer in
      let status = CMBlockBufferReplaceDataBytes(
        with: rawBuffer.baseAddress!,
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: data.count
      )
      guard status == kCMBlockBufferNoErr else {
        throw SyntheticCaptureServiceError.blockBufferCreationFailed(status)
      }
    }

    var streamDescription = AudioStreamBasicDescription(
      mSampleRate: Double(sampleRate),
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
      mBytesPerPacket: UInt32(bytesPerFrame),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(bytesPerFrame),
      mChannelsPerFrame: UInt32(channelCount),
      mBitsPerChannel: UInt32(bytesPerSample * 8),
      mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &streamDescription,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let formatDescription else {
      throw SyntheticCaptureServiceError.audioFormatDescriptionCreationFailed(formatStatus)
    }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
      presentationTimeStamp: CMTime(
        value: CMTimeValue(startSampleIndex), timescale: CMTimeScale(sampleRate)),
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: formatDescription,
      sampleCount: sampleCount,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
      throw SyntheticCaptureServiceError.sampleBufferCreationFailed(sampleStatus)
    }
    return sampleBuffer
  }
}

public enum SyntheticCaptureServiceError: Error, Equatable, LocalizedError {
  case pixelBufferCreationFailed(CVReturn)
  case pixelBufferBaseAddressUnavailable
  case blockBufferCreationFailed(OSStatus)
  case audioFormatDescriptionCreationFailed(OSStatus)
  case sampleBufferCreationFailed(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .pixelBufferCreationFailed(let status):
      "Synthetic test video pixel buffer creation failed with CVReturn \(status)."
    case .pixelBufferBaseAddressUnavailable:
      "Synthetic test video pixel buffer base address was unavailable."
    case .blockBufferCreationFailed(let status):
      "Synthetic test audio block buffer creation failed with OSStatus \(status)."
    case .audioFormatDescriptionCreationFailed(let status):
      "Synthetic test audio format description creation failed with OSStatus \(status)."
    case .sampleBufferCreationFailed(let status):
      "Synthetic test sample buffer creation failed with OSStatus \(status)."
    }
  }
}
