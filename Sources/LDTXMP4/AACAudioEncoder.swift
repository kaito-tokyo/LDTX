// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import OSLog

public enum AACAudioEncoderError: Error, LocalizedError {
  case invalidFormat
  case invalidSample
  case allocationFailed
  case conversionFailed(String)
  case sampleCreationFailed(OSStatus)
  case discontinuousPresentationTime(expected: CMTime, actual: CMTime, deltaFrames: Double)
  case finished

  public var errorDescription: String? {
    switch self {
    case .invalidFormat: "The AAC encoder format is invalid."
    case .invalidSample: "The AAC encoder received an invalid PCM sample."
    case .allocationFailed: "The AAC encoder could not allocate a buffer."
    case .conversionFailed(let reason): "AAC conversion failed: \(reason)"
    case .sampleCreationFailed(let status): "AAC sample creation failed with status \(status)."
    case .discontinuousPresentationTime(let expected, let actual, let deltaFrames):
      "AAC input presentation time is discontinuous (expected \(expected.seconds), actual \(actual.seconds), delta frames \(deltaFrames))."
    case .finished: "The AAC encoder has already finished."
    }
  }
}

/// Converts timestamped PCM sample buffers into timestamped raw AAC access units.
///
/// Instances are stateful and must be called from one serial executor.
public final class AACAudioEncoder: @unchecked Sendable {
  private static let logger = Logger(subsystem: "tokyo.kaito.ldtx", category: "AACAudioEncoder")
  private static let presentationTimeToleranceFrames = 2.0

  public let outputFormatDescription: CMAudioFormatDescription

  private let inputFormat: AVAudioFormat
  private let outputFormat: AVAudioFormat
  private let converter: AVAudioConverter
  private let sampleRate: Double
  private let leadingFrames: Int
  private var nextPresentationTime: CMTime?
  private var expectedInputPresentationTime: CMTime?
  private var inputFrameCount: Int64 = 0
  private var initialSamples: [CMSampleBuffer] = []
  private var initialPacketCount = 0
  private var hasEmittedInitialSample = false
  private var deferredSample: CMSampleBuffer?
  private var isFinished = false

  public init(
    inputFormatDescription: CMAudioFormatDescription,
    bitRate: Int = 128_000,
    outputSampleRate: Double? = nil,
    outputChannelCount: Int? = nil
  ) throws {
    let inputFormat = AVAudioFormat(cmAudioFormatDescription: inputFormatDescription)
    let targetSampleRate = outputSampleRate ?? inputFormat.sampleRate
    let targetChannelCount = outputChannelCount ?? Int(inputFormat.channelCount)
    guard inputFormat.sampleRate > 0,
      inputFormat.channelCount > 0,
      targetSampleRate > 0,
      targetChannelCount > 0,
      bitRate > 0,
      let outputFormat = AVAudioFormat(settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: targetSampleRate,
        AVNumberOfChannelsKey: targetChannelCount,
        AVEncoderBitRateKey: bitRate,
      ]),
      let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    else {
      throw AACAudioEncoderError.invalidFormat
    }
    self.inputFormat = inputFormat
    self.outputFormat = outputFormat
    self.converter = converter
    converter.primeMethod = .normal
    sampleRate = inputFormat.sampleRate
    leadingFrames = Int(converter.primeInfo.leadingFrames)
    outputFormatDescription = outputFormat.formatDescription
  }

  public func encode(_ sampleBuffer: CMSampleBuffer) throws -> [CMSampleBuffer] {
    guard !isFinished else { throw AACAudioEncoderError.finished }
    let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
    guard CMSampleBufferDataIsReady(sampleBuffer),
      frameCount > 0,
      sampleBuffer.presentationTimeStamp.isValid,
      let inputBuffer = AVAudioPCMBuffer(
        pcmFormat: inputFormat,
        frameCapacity: AVAudioFrameCount(frameCount))
    else {
      throw AACAudioEncoderError.invalidSample
    }
    try validatePresentationTime(
      sampleBuffer.presentationTimeStamp,
      frameCount: frameCount)
    inputBuffer.frameLength = AVAudioFrameCount(frameCount)
    let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer,
      at: 0,
      frameCount: Int32(frameCount),
      into: inputBuffer.mutableAudioBufferList)
    guard copyStatus == noErr else {
      throw AACAudioEncoderError.sampleCreationFailed(copyStatus)
    }
    if nextPresentationTime == nil {
      nextPresentationTime = CMTimeSubtract(
        sampleBuffer.presentationTimeStamp,
        frameDuration(leadingFrames))
    }
    return try stage(try convert(inputBuffer: inputBuffer, endOfStream: false), finishing: false)
  }

  private func validatePresentationTime(_ actual: CMTime, frameCount: Int) throws {
    let acceptedPresentationTime: CMTime
    if let expected = expectedInputPresentationTime {
      let deltaSeconds = CMTimeSubtract(actual, expected).seconds
      let deltaFrames = deltaSeconds * sampleRate
      guard deltaFrames.isFinite,
        abs(deltaFrames) <= Self.presentationTimeToleranceFrames
      else {
        Self.logger.error(
          "AAC input PTS discontinuity: expectedSeconds=\(expected.seconds, privacy: .public) actualSeconds=\(actual.seconds, privacy: .public) deltaFrames=\(deltaFrames, privacy: .public) sampleRate=\(self.sampleRate, privacy: .public) frameCount=\(frameCount, privacy: .public) cumulativeInputFrames=\(self.inputFrameCount, privacy: .public)"
        )
        throw AACAudioEncoderError.discontinuousPresentationTime(
          expected: expected,
          actual: actual,
          deltaFrames: deltaFrames)
      }
      acceptedPresentationTime = expected
    } else {
      acceptedPresentationTime = actual
    }
    expectedInputPresentationTime = CMTimeAdd(
      acceptedPresentationTime,
      CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(sampleRate)))
    inputFrameCount += Int64(frameCount)
  }

  public func finish() throws -> [CMSampleBuffer] {
    guard !isFinished else { return [] }
    isFinished = true
    return try stage(try convert(inputBuffer: nil, endOfStream: true), finishing: true)
  }

  private func stage(
    _ samples: [CMSampleBuffer],
    finishing: Bool
  ) throws -> [CMSampleBuffer] {
    var ready: [CMSampleBuffer] = []
    for sample in samples {
      if !hasEmittedInitialSample {
        initialSamples.append(sample)
        initialPacketCount += CMSampleBufferGetNumSamples(sample)
        if initialPacketCount * 1_024 > leadingFrames {
          let combined = try combine(initialSamples)
          initialSamples.removeAll(keepingCapacity: false)
          initialPacketCount = 0
          hasEmittedInitialSample = true
          setTrimDuration(
            frameDuration(leadingFrames), key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
            on: combined)
          ready.append(combined)
        }
      } else {
        ready.append(sample)
      }
    }

    if finishing, !hasEmittedInitialSample, !initialSamples.isEmpty {
      let combined = try combine(initialSamples)
      initialSamples.removeAll(keepingCapacity: false)
      initialPacketCount = 0
      hasEmittedInitialSample = true
      let availableFrames = CMSampleBufferGetNumSamples(combined) * 1_024
      setTrimDuration(
        frameDuration(min(leadingFrames, availableFrames)),
        key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
        on: combined)
      ready.append(combined)
    }

    var output: [CMSampleBuffer] = []
    for sample in ready {
      if let deferredSample { output.append(deferredSample) }
      deferredSample = sample
    }
    guard finishing else { return output }

    if let deferredSample {
      let trailingFrames = Int(converter.primeInfo.trailingFrames)
      if trailingFrames > 0 {
        setTrimDuration(
          frameDuration(trailingFrames),
          key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
          on: deferredSample)
      }
      output.append(deferredSample)
      self.deferredSample = nil
    }
    return output
  }

  private func combine(_ samples: [CMSampleBuffer]) throws -> CMSampleBuffer {
    let packetCount = samples.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }
    let byteCount = samples.reduce(0) { $0 + CMSampleBufferGetTotalSampleSize($1) }
    guard packetCount > 0, byteCount > 0,
      let presentationTime = samples.first?.presentationTimeStamp
    else { throw AACAudioEncoderError.invalidSample }

    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: byteCount,
      blockAllocator: nil,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: byteCount,
      flags: 0,
      blockBufferOut: &blockBuffer)
    guard status == kCMBlockBufferNoErr, let blockBuffer else {
      throw AACAudioEncoderError.sampleCreationFailed(status)
    }

    var destinationOffset = 0
    var sampleSizes: [Int] = []
    sampleSizes.reserveCapacity(packetCount)
    for sample in samples {
      guard let source = CMSampleBufferGetDataBuffer(sample) else {
        throw AACAudioEncoderError.invalidSample
      }
      let sourceLength = CMBlockBufferGetDataLength(source)
      var bytes = Data(count: sourceLength)
      status = bytes.withUnsafeMutableBytes { destination in
        CMBlockBufferCopyDataBytes(
          source,
          atOffset: 0,
          dataLength: sourceLength,
          destination: destination.baseAddress!)
      }
      guard status == kCMBlockBufferNoErr else {
        throw AACAudioEncoderError.sampleCreationFailed(status)
      }
      status = bytes.withUnsafeBytes { sourceBytes in
        CMBlockBufferReplaceDataBytes(
          with: sourceBytes.baseAddress!,
          blockBuffer: blockBuffer,
          offsetIntoDestination: destinationOffset,
          dataLength: sourceLength)
      }
      guard status == kCMBlockBufferNoErr else {
        throw AACAudioEncoderError.sampleCreationFailed(status)
      }
      destinationOffset += sourceLength
      for index in 0..<CMSampleBufferGetNumSamples(sample) {
        sampleSizes.append(CMSampleBufferGetSampleSize(sample, at: index))
      }
    }

    var timing = CMSampleTimingInfo(
      duration: frameDuration(1_024),
      presentationTimeStamp: presentationTime,
      decodeTimeStamp: .invalid)
    var combined: CMSampleBuffer?
    status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: outputFormatDescription,
      sampleCount: packetCount,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: packetCount,
      sampleSizeArray: &sampleSizes,
      sampleBufferOut: &combined)
    guard status == noErr, let combined else {
      throw AACAudioEncoderError.sampleCreationFailed(status)
    }
    return combined
  }

  private func frameDuration(_ frames: Int) -> CMTime {
    CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(sampleRate))
  }

  private func setTrimDuration(_ duration: CMTime, key: CFString, on sample: CMSampleBuffer) {
    CMSetAttachment(
      sample,
      key: key,
      value: CMTimeCopyAsDictionary(duration, allocator: kCFAllocatorDefault),
      attachmentMode: kCMAttachmentMode_ShouldPropagate)
  }

  private func convert(
    inputBuffer: AVAudioPCMBuffer?,
    endOfStream: Bool
  ) throws -> [CMSampleBuffer] {
    let provider = AACInputProvider(buffer: inputBuffer, endOfStream: endOfStream)
    var results: [CMSampleBuffer] = []
    while true {
      let inputFrameCount = Int(inputBuffer?.frameLength ?? 0)
      let packetCapacity = AVAudioPacketCount(max(1, (inputFrameCount + 1_023) / 1_024 + 2))
      let outputBuffer = AVAudioCompressedBuffer(
        format: outputFormat,
        packetCapacity: packetCapacity,
        maximumPacketSize: converter.maximumOutputPacketSize)
      var conversionError: NSError?
      let status = converter.convert(to: outputBuffer, error: &conversionError) {
        _, inputStatus in
        provider.provide(inputStatus: inputStatus)
      }
      if status == .error {
        throw AACAudioEncoderError.conversionFailed(
          conversionError?.localizedDescription ?? "Unknown converter error")
      }
      if outputBuffer.packetCount > 0 {
        results.append(try makeSampleBuffer(from: outputBuffer))
      }
      if status == .inputRanDry || status == .endOfStream { break }
    }
    return results
  }

  private func makeSampleBuffer(from buffer: AVAudioCompressedBuffer) throws -> CMSampleBuffer {
    let byteCount = Int(buffer.byteLength)
    let packetCount = Int(buffer.packetCount)
    guard byteCount > 0, packetCount > 0 else {
      throw AACAudioEncoderError.allocationFailed
    }

    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: byteCount,
      blockAllocator: nil,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: byteCount,
      flags: 0,
      blockBufferOut: &blockBuffer)
    guard status == kCMBlockBufferNoErr, let blockBuffer else {
      throw AACAudioEncoderError.sampleCreationFailed(status)
    }
    status = CMBlockBufferReplaceDataBytes(
      with: buffer.data,
      blockBuffer: blockBuffer,
      offsetIntoDestination: 0,
      dataLength: byteCount)
    guard status == kCMBlockBufferNoErr else {
      throw AACAudioEncoderError.sampleCreationFailed(status)
    }

    let packetDescriptions = buffer.packetDescriptions
    var sampleSizes: [Int] = (0..<packetCount).map { index in
      packetDescriptions.map { Int($0[index].mDataByteSize) } ?? byteCount
    }
    if packetDescriptions == nil, packetCount != 1 {
      throw AACAudioEncoderError.invalidSample
    }
    let presentationTime = nextPresentationTime ?? .zero
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1_024, timescale: CMTimeScale(sampleRate)),
      presentationTimeStamp: presentationTime,
      decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: outputFormatDescription,
      sampleCount: packetCount,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: packetCount,
      sampleSizeArray: &sampleSizes,
      sampleBufferOut: &sampleBuffer)
    guard status == noErr, let sampleBuffer else {
      throw AACAudioEncoderError.sampleCreationFailed(status)
    }
    nextPresentationTime = CMTimeAdd(
      presentationTime,
      CMTime(value: CMTimeValue(packetCount * 1_024), timescale: CMTimeScale(sampleRate)))
    return sampleBuffer
  }
}

private final class AACInputProvider: @unchecked Sendable {
  private var buffer: AVAudioPCMBuffer?
  private let endOfStream: Bool

  init(buffer: AVAudioPCMBuffer?, endOfStream: Bool) {
    self.buffer = buffer
    self.endOfStream = endOfStream
  }

  func provide(inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    if let buffer {
      self.buffer = nil
      inputStatus.pointee = .haveData
      return buffer
    }
    inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
    return nil
  }
}
