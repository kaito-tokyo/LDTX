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
  private var pendingAAC: [CMSampleBuffer] = []
  private var didFinishEncoder = false
  private var nextSegmentNumber: Int
  private var didStartSession = false
  private var isFinishing = false
  private var isDrainScheduled = false
  private var storedFailure: Error?
  private var nextPresentationTime: CMTime?
  private var lastFormat: CMAudioFormatDescription?
  private var finishTime: CMTime?
  private let initialFormat: CMAudioFormatDescription
  private let pcmNormalizer: AudioSampleBufferNormalizer
  private let aacEncoder: AACAudioEncoder
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
    pcmNormalizer = try AudioSampleBufferNormalizer(
      sampleRate: description.mSampleRate, channelCount: description.mChannelsPerFrame)
    guard
      let recordingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: description.mSampleRate,
        channels: description.mChannelsPerFrame, interleaved: true)
    else { throw PCMAudioSegmentedMP4WriterError.invalidConfiguration }
    initialFormat = recordingFormat.formatDescription
    aacEncoder = try AACAudioEncoder(inputFormatDescription: initialFormat, bitRate: bitRate)
    self.onFailure = onFailure
    nextSegmentNumber = startNumber
    assetWriter = AVAssetWriter(contentType: .mpeg4Movie)
    assetWriter.outputFileTypeProfile = .mpeg4AppleHLS
    assetWriter.preferredOutputSegmentInterval = CMTime(
      seconds: Double(targetSegmentDurationSeconds), preferredTimescale: 1)
    assetWriter.initialSegmentStartTime = .zero
    audioInput = AVAssetWriterInput(
      // Keep PCM-to-AAC conversion outside the segmented writer, as in the
      // main recording pipeline. The writer only receives compressed samples.
      mediaType: .audio,
      outputSettings: nil,
      sourceFormatHint: aacEncoder.outputFormatDescription
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
      do {
        // AVAssetWriter retains its initial PCM interpretation across format
        // changes. Convert explicitly while keeping the source presentation time.
        if let normalized = try pcmNormalizer.normalize(sampleBuffer.value) {
          pending.append(normalized)
        }
      } catch {
        fail(error)
        return
      }
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
      if !pendingAAC.isEmpty {
        guard audioInput.append(pendingAAC.removeFirst()) else {
          fail(
            PCMAudioSegmentedMP4WriterError.writerFailed(
              assetWriter.error?.localizedDescription ?? "append AAC failed"))
          return
        }
        continue
      }
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
            encodePCM(
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
            guard encodePCM(silence) else { return }
            continue
          } catch {
            fail(error)
            return
          }
        }
      }
      guard encodePCM(pending.removeFirst()) else { return }
    }
  }

  private func encodePCM(_ sample: CMSampleBuffer) -> Bool {
    do {
      pendingAAC.append(contentsOf: try aacEncoder.encode(sample))
    } catch {
      fail(error)
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
    guard !pending.isEmpty || !pendingAAC.isEmpty || needsTrailingSilence,
      !isDrainScheduled, storedFailure == nil
    else {
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
    guard storedFailure == nil else { return }
    guard pending.isEmpty && !needsTrailingSilence else {
      scheduleDrainIfNeeded()
      return
    }
    guard didStartSession else {
      self.finishHandler = nil
      if assetWriter.status == .writing {
        AVAssetWriterLifecycleGate.cancel { assetWriter.cancelWriting() }
      }
      finishHandler(.success(()))
      return
    }
    if !didFinishEncoder {
      do {
        pendingAAC.append(contentsOf: try aacEncoder.finish())
        didFinishEncoder = true
      } catch {
        fail(error)
        return
      }
    }
    drain()
    guard storedFailure == nil else { return }
    guard pendingAAC.isEmpty else {
      scheduleDrainIfNeeded()
      return
    }
    self.finishHandler = nil
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
    pendingAAC.removeAll()
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
