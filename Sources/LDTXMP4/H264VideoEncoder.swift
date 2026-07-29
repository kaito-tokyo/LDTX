// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import VideoToolbox

public struct H264VideoEncoderConfiguration: Equatable, Sendable {
  static let maximumMacroblocksPerFrame = 8_704
  static let maximumMacroblocksPerSecond = 522_240
  static let maximumBitRate = 62_500_000

  public var width: Int
  public var height: Int
  public var frameRate: Int
  public var bitRate: Int
  public var keyFrameIntervalSeconds: Int
  public var requiresHardwareAcceleration: Bool

  public init(
    width: Int,
    height: Int,
    frameRate: Int,
    bitRate: Int,
    keyFrameIntervalSeconds: Int = 2,
    requiresHardwareAcceleration: Bool = true
  ) {
    self.width = width
    self.height = height
    self.frameRate = frameRate
    self.bitRate = bitRate
    self.keyFrameIntervalSeconds = keyFrameIntervalSeconds
    self.requiresHardwareAcceleration = requiresHardwareAcceleration
  }

  func validate() throws {
    guard width > 0, height > 0,
      width.isMultiple(of: 2), height.isMultiple(of: 2),
      frameRate > 0, bitRate > 0, bitRate <= Self.maximumBitRate,
      keyFrameIntervalSeconds > 0
    else {
      throw H264VideoEncoderError.invalidConfiguration
    }
    let macroblocksPerFrame = ((width + 15) / 16) * ((height + 15) / 16)
    let macroblocksPerSecond = macroblocksPerFrame.multipliedReportingOverflow(by: frameRate)
    guard macroblocksPerFrame <= Self.maximumMacroblocksPerFrame,
      !macroblocksPerSecond.overflow,
      macroblocksPerSecond.partialValue <= Self.maximumMacroblocksPerSecond
    else {
      throw H264VideoEncoderError.invalidConfiguration
    }
  }
}

public enum H264VideoEncoderError: Error, LocalizedError {
  case invalidConfiguration
  case videoToolbox(operation: String, status: OSStatus)
  case finished
  case unsupportedProperty(String)
  case configurationMismatch(property: String, expected: String, actual: String)
  case unexpectedBitstreamProfile(String)
  case invalidPixelBuffer

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "The H.264 encoder configuration is invalid."
    case .videoToolbox(let operation, let status):
      "VideoToolbox \(operation) failed with status \(status)."
    case .finished:
      "The H.264 encoder has already finished."
    case .unsupportedProperty(let property):
      "The H.264 encoder does not support required property \(property)."
    case .configurationMismatch(let property, let expected, let actual):
      "The H.264 encoder applied \(property)=\(actual), not required \(expected)."
    case .unexpectedBitstreamProfile(let codec):
      "The H.264 encoder produced \(codec), not required avc1.64002a."
    case .invalidPixelBuffer:
      "The H.264 encoder requires a matching NV12 video-range pixel buffer."
    }
  }
}

public final class H264VideoEncoder: @unchecked Sendable {
  public typealias OutputHandler = @Sendable (Result<CMSampleBuffer, any Error>) -> Void

  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.H264VideoEncoder")
  private let configuration: H264VideoEncoderConfiguration
  private let outputHandler: OutputHandler
  private var compressionSession: VTCompressionSession?
  private var forceNextKeyFrame = false
  private var isFinished = false

  public init(
    configuration: H264VideoEncoderConfiguration,
    outputHandler: @escaping OutputHandler
  ) throws {
    try configuration.validate()
    self.configuration = configuration
    self.outputHandler = outputHandler

    var session: VTCompressionSession?
    let encoderSpecification: CFDictionary? =
      configuration.requiresHardwareAcceleration
      ? [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue]
        as CFDictionary
      : nil
    let status = VTCompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      width: Int32(configuration.width),
      height: Int32(configuration.height),
      codecType: kCMVideoCodecType_H264,
      encoderSpecification: encoderSpecification,
      imageBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String:
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      ] as CFDictionary,
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
      try Self.requireSupported(session, key: kVTCompressionPropertyKey_ConstantBitRate)
      try Self.setProperty(
        session, key: kVTCompressionPropertyKey_ConstantBitRate, value: configuration.bitRate)
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
        value: kVTProfileLevel_H264_High_4_2
      )
      try Self.setProperty(
        session,
        key: kVTCompressionPropertyKey_ColorPrimaries,
        value: kCVImageBufferColorPrimaries_ITU_R_709_2
      )
      try Self.setProperty(
        session,
        key: kVTCompressionPropertyKey_TransferFunction,
        value: kCVImageBufferTransferFunction_ITU_R_709_2
      )
      try Self.setProperty(
        session,
        key: kVTCompressionPropertyKey_YCbCrMatrix,
        value: kCVImageBufferYCbCrMatrix_ITU_R_709_2
      )
      try Self.requireSupported(session, key: kVTCompressionPropertyKey_AllowOpenGOP)
      try Self.setProperty(session, key: kVTCompressionPropertyKey_AllowOpenGOP, value: false)
      let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
      guard prepareStatus == noErr else {
        throw H264VideoEncoderError.videoToolbox(
          operation: "VTCompressionSessionPrepareToEncodeFrames",
          status: prepareStatus
        )
      }
      try Self.requirePropertyValue(
        session, key: kVTCompressionPropertyKey_RealTime, expected: true)
      try Self.requirePropertyValue(
        session, key: kVTCompressionPropertyKey_AllowFrameReordering, expected: false)
      try Self.requirePropertyValue(
        session, key: kVTCompressionPropertyKey_ConstantBitRate, expected: configuration.bitRate)
      try Self.requirePropertyValue(
        session, key: kVTCompressionPropertyKey_ExpectedFrameRate, expected: configuration.frameRate
      )
      try Self.requirePropertyValue(
        session,
        key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
        expected: configuration.frameRate * configuration.keyFrameIntervalSeconds)
      try Self.requirePropertyValue(
        session,
        key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
        expected: configuration.keyFrameIntervalSeconds)
      try Self.requirePropertyValue(
        session, key: kVTCompressionPropertyKey_ProfileLevel,
        expected: kVTProfileLevel_H264_High_4_2)
      try Self.requirePropertyValue(
        session,
        key: kVTCompressionPropertyKey_ColorPrimaries,
        expected: kCVImageBufferColorPrimaries_ITU_R_709_2)
      try Self.requirePropertyValue(
        session,
        key: kVTCompressionPropertyKey_TransferFunction,
        expected: kCVImageBufferTransferFunction_ITU_R_709_2)
      try Self.requirePropertyValue(
        session,
        key: kVTCompressionPropertyKey_YCbCrMatrix,
        expected: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
      try Self.requirePropertyValue(
        session, key: kVTCompressionPropertyKey_AllowOpenGOP, expected: false)
      if configuration.requiresHardwareAcceleration {
        try Self.requirePropertyValue(
          session,
          key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
          expected: true)
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
    guard
      CVPixelBufferGetPixelFormatType(pixelBuffer)
        == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      CVPixelBufferGetWidth(pixelBuffer) == configuration.width,
      CVPixelBufferGetHeight(pixelBuffer) == configuration.height
    else {
      outputHandler(.failure(H264VideoEncoderError.invalidPixelBuffer))
      return
    }
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
    do {
      guard try Self.codecString(from: sampleBuffer) == "avc1.64002a" else {
        outputHandler(
          .failure(
            H264VideoEncoderError.unexpectedBitstreamProfile(
              try Self.codecString(from: sampleBuffer))))
        return
      }
    } catch {
      outputHandler(.failure(error))
      return
    }
    outputHandler(.success(sampleBuffer))
  }

  /// RFC 6381 AVC codec identifier derived from the first SPS in an AVCC sample.
  public static func codecString(from sampleBuffer: CMSampleBuffer) throws -> String {
    guard let formatDescription = sampleBuffer.formatDescription,
      CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_H264
    else {
      throw H264VideoEncoderError.unexpectedBitstreamProfile("non-H.264")
    }
    var pointer: UnsafePointer<UInt8>?
    var size = 0
    let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      formatDescription,
      parameterSetIndex: 0,
      parameterSetPointerOut: &pointer,
      parameterSetSizeOut: &size,
      parameterSetCountOut: nil,
      nalUnitHeaderLengthOut: nil
    )
    guard status == noErr, let pointer, size >= 4, pointer[0] & 0x1F == 7 else {
      throw H264VideoEncoderError.unexpectedBitstreamProfile("missing SPS")
    }
    return String(format: "avc1.%02x%02x%02x", pointer[1], pointer[2], pointer[3])
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

  private static func requireSupported(_ session: VTCompressionSession, key: CFString) throws {
    var properties: CFDictionary?
    let status = VTSessionCopySupportedPropertyDictionary(
      session, supportedPropertyDictionaryOut: &properties)
    guard status == noErr, let properties,
      CFDictionaryContainsKey(properties, Unmanaged.passUnretained(key).toOpaque())
    else {
      throw H264VideoEncoderError.unsupportedProperty(key as String)
    }
  }

  private static func requirePropertyValue(
    _ session: VTCompressionSession,
    key: CFString,
    expected: some Any
  ) throws {
    var copiedValue: Unmanaged<CFTypeRef>?
    let status = VTSessionCopyProperty(
      session,
      key: key,
      allocator: kCFAllocatorDefault,
      valueOut: &copiedValue)
    guard status == noErr, let copiedValue else {
      throw H264VideoEncoderError.videoToolbox(
        operation: "VTSessionCopyProperty(\(key))",
        status: status)
    }
    let actual = copiedValue.takeRetainedValue()
    let expected = expected as CFTypeRef
    guard CFEqual(actual, expected) else {
      throw H264VideoEncoderError.configurationMismatch(
        property: key as String,
        expected: String(describing: expected),
        actual: String(describing: actual))
    }
  }
}

private struct SendablePixelBuffer: @unchecked Sendable {
  var value: CVPixelBuffer
}
