// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import VideoToolbox

public struct H264VideoEncoderConfiguration: Equatable, Sendable {
  public var width: Int
  public var height: Int
  public var frameRate: Int
  public var bitRate: Int
  public var keyFrameIntervalSeconds: Int

  public init(
    width: Int,
    height: Int,
    frameRate: Int,
    bitRate: Int,
    keyFrameIntervalSeconds: Int = 2
  ) {
    self.width = width
    self.height = height
    self.frameRate = frameRate
    self.bitRate = bitRate
    self.keyFrameIntervalSeconds = keyFrameIntervalSeconds
  }
}

public enum H264VideoEncoderError: Error, LocalizedError {
  case invalidConfiguration
  case videoToolbox(operation: String, status: OSStatus)
  case finished

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "The H.264 encoder configuration is invalid."
    case .videoToolbox(let operation, let status):
      "VideoToolbox \(operation) failed with status \(status)."
    case .finished:
      "The H.264 encoder has already finished."
    }
  }
}

public final class H264VideoEncoder: @unchecked Sendable {
  public typealias OutputHandler = @Sendable (Result<CMSampleBuffer, any Error>) -> Void

  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.H264VideoEncoder")
  private let outputHandler: OutputHandler
  private var compressionSession: VTCompressionSession?
  private var forceNextKeyFrame = false
  private var isFinished = false

  public init(
    configuration: H264VideoEncoderConfiguration,
    outputHandler: @escaping OutputHandler
  ) throws {
    guard configuration.width > 0,
      configuration.height > 0,
      configuration.frameRate > 0,
      configuration.bitRate > 0,
      configuration.keyFrameIntervalSeconds > 0
    else {
      throw H264VideoEncoderError.invalidConfiguration
    }
    self.outputHandler = outputHandler

    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      width: Int32(configuration.width),
      height: Int32(configuration.height),
      codecType: kCMVideoCodecType_H264,
      encoderSpecification: nil,
      imageBufferAttributes: nil,
      compressedDataAllocator: nil,
      outputCallback: Self.outputCallback,
      refcon: Unmanaged.passUnretained(self).toOpaque(),
      compressionSessionOut: &session
    )
    guard status == noErr, let session else {
      throw H264VideoEncoderError.videoToolbox(
        operation: "VTCompressionSessionCreate",
        status: status
      )
    }
    compressionSession = session

    do {
      try Self.setProperty(session, key: kVTCompressionPropertyKey_RealTime, value: true)
      try Self.setProperty(
        session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: false)
      try Self.setProperty(
        session,
        key: kVTCompressionPropertyKey_AverageBitRate,
        value: configuration.bitRate
      )
      try Self.setProperty(
        session,
        key: kVTCompressionPropertyKey_ExpectedFrameRate,
        value: configuration.frameRate
      )
      try Self.setProperty(
        session,
        key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
        value: configuration.frameRate * configuration.keyFrameIntervalSeconds
      )
      try Self.setProperty(
        session,
        key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
        value: configuration.keyFrameIntervalSeconds
      )
      try Self.setProperty(
        session,
        key: kVTCompressionPropertyKey_ProfileLevel,
        value: kVTProfileLevel_H264_High_AutoLevel
      )
      let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
      guard prepareStatus == noErr else {
        throw H264VideoEncoderError.videoToolbox(
          operation: "VTCompressionSessionPrepareToEncodeFrames",
          status: prepareStatus
        )
      }
    } catch {
      VTCompressionSessionInvalidate(session)
      compressionSession = nil
      throw error
    }
  }

  deinit {
    if let compressionSession {
      VTCompressionSessionInvalidate(compressionSession)
    }
  }

  public func encode(
    pixelBuffer: CVPixelBuffer,
    presentationTime: CMTime,
    duration: CMTime = .invalid
  ) {
    let pixelBuffer = SendablePixelBuffer(value: pixelBuffer)
    queue.async { [self] in
      guard !isFinished, let compressionSession else {
        outputHandler(.failure(H264VideoEncoderError.finished))
        return
      }
      let frameProperties: CFDictionary? =
        if forceNextKeyFrame {
          [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        } else {
          nil
        }
      forceNextKeyFrame = false
      let status = VTCompressionSessionEncodeFrame(
        compressionSession,
        imageBuffer: pixelBuffer.value,
        presentationTimeStamp: presentationTime,
        duration: duration,
        frameProperties: frameProperties,
        sourceFrameRefcon: nil,
        infoFlagsOut: nil
      )
      if status != noErr {
        outputHandler(
          .failure(
            H264VideoEncoderError.videoToolbox(
              operation: "VTCompressionSessionEncodeFrame",
              status: status
            )))
      }
    }
  }

  public func requestKeyFrame() {
    queue.async { [self] in
      guard !isFinished else { return }
      forceNextKeyFrame = true
    }
  }

  public func finish(
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    queue.async { [self] in
      guard !isFinished else {
        completionHandler(.success(()))
        return
      }
      isFinished = true
      guard let compressionSession else {
        completionHandler(.success(()))
        return
      }
      let status = VTCompressionSessionCompleteFrames(
        compressionSession,
        untilPresentationTimeStamp: .invalid
      )
      VTCompressionSessionInvalidate(compressionSession)
      self.compressionSession = nil
      guard status == noErr else {
        completionHandler(
          .failure(
            H264VideoEncoderError.videoToolbox(
              operation: "VTCompressionSessionCompleteFrames",
              status: status
            )))
        return
      }
      completionHandler(.success(()))
    }
  }

  private func didEncode(
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
  ) {
    guard status == noErr else {
      outputHandler(
        .failure(
          H264VideoEncoderError.videoToolbox(
            operation: "compression output callback",
            status: status
          )))
      return
    }
    guard !infoFlags.contains(.frameDropped),
      let sampleBuffer,
      CMSampleBufferDataIsReady(sampleBuffer)
    else {
      return
    }
    outputHandler(.success(sampleBuffer))
  }

  private static let outputCallback: VTCompressionOutputCallback = {
    outputCallbackRefCon,
    _,
    status,
    infoFlags,
    sampleBuffer in
    guard let outputCallbackRefCon else { return }
    let encoder = Unmanaged<H264VideoEncoder>
      .fromOpaque(outputCallbackRefCon)
      .takeUnretainedValue()
    encoder.didEncode(status: status, infoFlags: infoFlags, sampleBuffer: sampleBuffer)
  }

  private static func setProperty(
    _ session: VTCompressionSession,
    key: CFString,
    value: Any
  ) throws {
    let status = VTSessionSetProperty(
      session,
      key: key,
      value: value as CFTypeRef
    )
    guard status == noErr else {
      throw H264VideoEncoderError.videoToolbox(
        operation: "VTSessionSetProperty(\(key))",
        status: status
      )
    }
  }
}

private struct SendablePixelBuffer: @unchecked Sendable {
  var value: CVPixelBuffer
}
