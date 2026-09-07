// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public final class PCMAudioSegmentedMP4Writer: NSObject, AVAssetWriterDelegate, @unchecked Sendable
{
  public typealias SegmentHandler = @Sendable (SegmentedMP4Segment) -> Void

  private let assetWriter: AVAssetWriter
  private let audioInput: AVAssetWriterInput
  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.PCMAudioSegmentedMP4Writer")
  private let onSegment: SegmentHandler
  private let onFailure: @Sendable (any Error) -> Void
  private var pending: [CMSampleBuffer] = []
  private var nextSegmentNumber: Int
  private var didStartSession = false
  private var isFinishing = false
  private var isDrainScheduled = false
  private var storedFailure: Error?
  private var nextPresentationTime: CMTime?
  private var lastFormat: CMAudioFormatDescription?
  private var finishTime: CMTime?
  private let initialFormat: CMAudioFormatDescription
  private var finishHandler: (@Sendable (Result<Void, any Error>) -> Void)?

  public init(
    formatDescription: CMAudioFormatDescription,
    bitRate: Int = 128_000,
    targetSegmentDurationSeconds: Int,
    startNumber: Int = 1,
    onFailure: @escaping @Sendable (any Error) -> Void = { _ in },
    onSegment: @escaping SegmentHandler
  ) throws {
    guard
      let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?
        .pointee,
      description.mSampleRate > 0,
      description.mChannelsPerFrame > 0,
      bitRate > 0,
      targetSegmentDurationSeconds > 0,
      startNumber > 0
    else {
      throw PCMAudioSegmentedMP4WriterError.invalidConfiguration
    }
    self.onSegment = onSegment
    initialFormat = formatDescription
    self.onFailure = onFailure
    nextSegmentNumber = startNumber
    assetWriter = AVAssetWriter(contentType: .mpeg4Movie)
    assetWriter.outputFileTypeProfile = .mpeg4AppleHLS
    assetWriter.preferredOutputSegmentInterval = CMTime(
      seconds: Double(targetSegmentDurationSeconds), preferredTimescale: 1)
    assetWriter.initialSegmentStartTime = .zero
    audioInput = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: description.mSampleRate,
        AVNumberOfChannelsKey: Int(description.mChannelsPerFrame),
        AVEncoderBitRateKey: bitRate,
      ],
      sourceFormatHint: formatDescription
    )
    audioInput.expectsMediaDataInRealTime = true
    super.init()
    assetWriter.delegate = self
    guard assetWriter.canAdd(audioInput) else {
      throw PCMAudioSegmentedMP4WriterError.cannotAddInput
    }
    assetWriter.add(audioInput)
  }

  public func append(_ sampleBuffer: CMSampleBuffer) {
    let sampleBuffer = SendablePCMSampleBuffer(value: sampleBuffer)
    queue.async { [self] in
      guard !isFinishing, storedFailure == nil else { return }
      if !didStartSession {
        do {
          try AVAssetWriterLifecycleGate.start { try assetWriter.start() }
        } catch {
          fail(PCMAudioSegmentedMP4WriterError.writerFailed(error.localizedDescription))
          return
        }
        assetWriter.startSession(atSourceTime: .zero)
        didStartSession = true
      }
      pending.append(sampleBuffer.value)
      drain()
      scheduleDrainIfNeeded()
    }
  }

  public func finish(
    at presentationTime: CMTime? = nil,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    queue.async { [self] in
      guard !isFinishing else {
        completionHandler(.success(()))
        return
      }
      isFinishing = true
      finishTime = presentationTime?.isNumeric == true ? presentationTime : nil
      if let storedFailure {
        completionHandler(.failure(storedFailure))
        return
      }
      finishHandler = completionHandler
      if !didStartSession, let finishTime, CMTimeCompare(finishTime, .zero) > 0 {
        do {
          try AVAssetWriterLifecycleGate.start { try assetWriter.start() }
          assetWriter.startSession(atSourceTime: .zero)
          didStartSession = true
          nextPresentationTime = .zero
          lastFormat = initialFormat
        } catch {
          fail(error)
          return
        }
      }
      finishWhenDrained()
    }
  }

  func cancel(with error: any Error) {
    queue.async { [self] in fail(error) }
  }

  public func assetWriter(
    _ writer: AVAssetWriter,
    didOutputSegmentData segmentData: Data,
    segmentType: AVAssetSegmentType,
    segmentReport: AVAssetSegmentReport?
  ) {
    queue.async { [self] in
      switch segmentType {
      case .initialization:
        onSegment(SegmentedMP4Segment(kind: .initialization, data: segmentData))
      case .separable:
        let number = nextSegmentNumber
        nextSegmentNumber += 1
        onSegment(
          SegmentedMP4Segment(
            kind: .media(number: number),
            data: segmentData,
            durationSeconds: Self.durationSeconds(from: segmentReport),
            earliestPresentationTimeSeconds: Self.earliestPresentationTimeSeconds(
              from: segmentReport)))
      @unknown default:
        break
      }
    }
  }

  private func drain() {
    guard assetWriter.status == .writing else { return }
    while audioInput.isReadyForMoreMediaData {
      if pending.isEmpty {
        guard let finishTime, let cursor = nextPresentationTime, let format = lastFormat,
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return }
        let remaining = CMTimeConvertScale(
          CMTimeSubtract(finishTime, cursor), timescale: Int32(asbd.mSampleRate),
          method: .roundHalfAwayFromZero)
        guard remaining.isNumeric && remaining.value > 0 else {
          self.finishTime = nil
          return
        }
        do {
          guard
            appendToWriter(
              try makeSilence(
                format: format, at: cursor, frames: Int(min(remaining.value, 1_024))))
          else { return }
        } catch {
          fail(error)
          return
        }
        continue
      }
      let next = pending[0]
      if let cursor = nextPresentationTime,
        let format = next.formatDescription,
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
      {
        let gap = CMTimeConvertScale(
          CMTimeSubtract(next.presentationTimeStamp, cursor),
          timescale: Int32(asbd.mSampleRate), method: .roundHalfAwayFromZero)
        if gap.isNumeric && gap.value > 1 {
          do {
            let silence = try makeSilence(
              format: format, at: cursor, frames: Int(min(gap.value, 1_024)))
            guard appendToWriter(silence) else { return }
            continue
          } catch {
            fail(error)
            return
          }
        }
      }
      guard appendToWriter(pending.removeFirst()) else { return }
    }
  }

  private func appendToWriter(_ sample: CMSampleBuffer) -> Bool {
    if !audioInput.append(sample) {
      fail(
        PCMAudioSegmentedMP4WriterError.writerFailed(
          assetWriter.error?.localizedDescription ?? "append failed"))
      return false
    }
    nextPresentationTime = CMTimeAdd(sample.presentationTimeStamp, sample.duration)
    lastFormat = sample.formatDescription
    return true
  }

  private func makeSilence(
    format: CMAudioFormatDescription, at time: CMTime, frames: Int
  ) throws -> CMSampleBuffer {
    let audioFormat = AVAudioFormat(cmAudioFormatDescription: format)
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frames))
    else { throw PCMAudioSegmentedMP4WriterError.invalidConfiguration }
    buffer.frameLength = AVAudioFrameCount(frames)
    for plane in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
      if let data = plane.mData {
        memset(data, 0, Int(plane.mDataByteSize))
      }
    }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: Int32(audioFormat.sampleRate)),
      presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: nil, formatDescription: format,
        sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
      let sample,
      CMSampleBufferSetDataBufferFromAudioBufferList(
        sample, blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
        bufferList: buffer.audioBufferList) == noErr
    else { throw PCMAudioSegmentedMP4WriterError.invalidConfiguration }
    return sample
  }

  private func scheduleDrainIfNeeded() {
    guard !pending.isEmpty || needsTrailingSilence, !isDrainScheduled, storedFailure == nil else {
      return
    }
    isDrainScheduled = true
    queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
      guard let self else { return }
      self.isDrainScheduled = false
      self.drain()
      self.finishWhenDrained()
      self.scheduleDrainIfNeeded()
    }
  }

  private func finishWhenDrained() {
    guard isFinishing, let finishHandler else { return }
    if assetWriter.status == .failed || assetWriter.status == .cancelled {
      fail(
        PCMAudioSegmentedMP4WriterError.writerFailed(
          assetWriter.error?.localizedDescription ?? "writer stopped before pending media drained"))
      return
    }
    drain()
    guard pending.isEmpty && !needsTrailingSilence else {
      scheduleDrainIfNeeded()
      return
    }
    self.finishHandler = nil
    guard didStartSession else {
      if assetWriter.status == .writing {
        AVAssetWriterLifecycleGate.cancel { assetWriter.cancelWriting() }
      }
      finishHandler(.success(()))
      return
    }
    audioInput.markAsFinished()
    AVAssetWriterLifecycleGate.finish(
      { [self] completion in
        self.assetWriter.finishWriting(completionHandler: completion)
      },
      completion: { [self] in
        queue.async {
          if self.assetWriter.status == .failed {
            let error = PCMAudioSegmentedMP4WriterError.writerFailed(
              self.assetWriter.error?.localizedDescription ?? "finish failed")
            self.fail(error)
            finishHandler(.failure(error))
          } else {
            finishHandler(.success(()))
          }
        }
      })
  }

  private func fail(_ error: Error) {
    guard storedFailure == nil else { return }
    storedFailure = error
    pending.removeAll()
    if assetWriter.status == .writing {
      AVAssetWriterLifecycleGate.cancel { assetWriter.cancelWriting() }
    }
    onFailure(error)
    finishHandler?(.failure(error))
    finishHandler = nil
  }

  private var needsTrailingSilence: Bool {
    guard let finishTime, let nextPresentationTime else { return false }
    return CMTimeCompare(finishTime, nextPresentationTime) > 0
  }

  private static func durationSeconds(from report: AVAssetSegmentReport?) -> Double? {
    report?.trackReports.map(\.duration.seconds).filter { $0.isFinite && $0 > 0 }.max()
  }

  private static func earliestPresentationTimeSeconds(
    from report: AVAssetSegmentReport?
  ) -> Double? {
    report?.trackReports.map(\.earliestPresentationTimeStamp.seconds).filter(\.isFinite).min()
  }
}

public enum PCMAudioSegmentedMP4WriterError: Error, LocalizedError {
  case invalidConfiguration
  case cannotAddInput
  case writerFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "The PCM audio writer configuration is invalid."
    case .cannotAddInput: "The PCM audio writer cannot add its input."
    case .writerFailed(let reason): "The PCM audio writer failed: \(reason)"
    }
  }
}

private struct SendablePCMSampleBuffer: @unchecked Sendable {
  var value: CMSampleBuffer
}
