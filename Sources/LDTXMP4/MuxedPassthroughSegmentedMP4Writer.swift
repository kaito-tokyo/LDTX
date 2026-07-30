// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public enum MuxedPassthroughSegmentedMP4WriterError: Error, LocalizedError {
  case invalidConfiguration
  case invalidVideoFormat
  case invalidAudioFormat
  case cannotAddVideoInput
  case cannotAddAudioInput
  case writerFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "The muxed passthrough writer configuration is invalid."
    case .invalidVideoFormat: "The muxed passthrough writer requires H.264 video."
    case .invalidAudioFormat: "The muxed passthrough writer requires AAC audio."
    case .cannotAddVideoInput: "The muxed passthrough writer cannot add its video input."
    case .cannotAddAudioInput: "The muxed passthrough writer cannot add its audio input."
    case .writerFailed(let reason): "The muxed passthrough writer failed: \(reason)"
    }
  }
}

/// Muxes pre-encoded H.264 and AAC into fragmented MP4 without rewriting boxes.
public final class MuxedPassthroughSegmentedMP4Writer: NSObject, AVAssetWriterDelegate,
  @unchecked Sendable
{
  public typealias SegmentHandler = @Sendable (SegmentedMP4Segment) -> Void

  private enum Track { case video, audio }
  private struct PendingSample {
    var track: Track
    var buffer: CMSampleBuffer
    var isSyncVideo: Bool
    var sortTime: CMTime
  }

  private let assetWriter: AVAssetWriter
  private let videoInput: AVAssetWriterInput
  private let audioInput: AVAssetWriterInput
  private let targetSegmentDuration: CMTime
  private let onSegment: SegmentHandler
  private let onFailure: @Sendable (any Error) -> Void
  private let queue = DispatchQueue(
    label: "tokyo.kaito.ldtx.MuxedPassthroughSegmentedMP4Writer")
  private var pending: [PendingSample] = []
  private var nextSegmentNumber: Int
  private var segmentStartTime: CMTime?
  private var latestVideoTime: CMTime?
  private var latestAudioTime: CMTime?
  private var hasAppendedSample = false
  /// A fragmented H.264 asset may only begin at a random-access sample.  The
  /// audio producer can legitimately outrun video, so never let AAC start an
  /// AVAssetWriter segment while waiting for the first IDR.
  private var hasStartedAtSyncVideo = false
  private var isFinishing = false
  private var isDrainScheduled = false
  private var storedFailure: (any Error)?
  private var finishHandler: (@Sendable (Result<Void, any Error>) -> Void)?

  public init(
    videoFormatDescription: CMVideoFormatDescription,
    audioFormatDescription: CMAudioFormatDescription,
    segmentDurationSeconds: Int,
    startNumber: Int = 1,
    onFailure: @escaping @Sendable (any Error) -> Void = { _ in },
    onSegment: @escaping SegmentHandler
  ) throws {
    guard segmentDurationSeconds > 0, startNumber > 0 else {
      throw MuxedPassthroughSegmentedMP4WriterError.invalidConfiguration
    }
    guard CMFormatDescriptionGetMediaSubType(videoFormatDescription) == kCMVideoCodecType_H264
    else { throw MuxedPassthroughSegmentedMP4WriterError.invalidVideoFormat }
    guard CMFormatDescriptionGetMediaSubType(audioFormatDescription) == kAudioFormatMPEG4AAC
    else { throw MuxedPassthroughSegmentedMP4WriterError.invalidAudioFormat }

    targetSegmentDuration = CMTime(seconds: Double(segmentDurationSeconds), preferredTimescale: 600)
    nextSegmentNumber = startNumber
    self.onFailure = onFailure
    self.onSegment = onSegment
    assetWriter = AVAssetWriter(contentType: .mpeg4Movie)
    assetWriter.outputFileTypeProfile = .mpeg4AppleHLS
    assetWriter.preferredOutputSegmentInterval = .indefinite
    videoInput = AVAssetWriterInput(
      mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormatDescription)
    audioInput = AVAssetWriterInput(
      mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormatDescription)
    videoInput.expectsMediaDataInRealTime = true
    audioInput.expectsMediaDataInRealTime = true
    videoInput.mediaDataLocation = .interleavedWithMainMediaData
    audioInput.mediaDataLocation = .interleavedWithMainMediaData

    super.init()
    assetWriter.delegate = self
    guard assetWriter.canAdd(videoInput) else {
      throw MuxedPassthroughSegmentedMP4WriterError.cannotAddVideoInput
    }
    assetWriter.add(videoInput)
    guard assetWriter.canAdd(audioInput) else {
      throw MuxedPassthroughSegmentedMP4WriterError.cannotAddAudioInput
    }
    assetWriter.add(audioInput)
    do {
      try assetWriter.start()
    } catch {
      throw Self.writerError(error)
    }
    assetWriter.startSession(atSourceTime: .zero)
  }

  public func append(video: [CMSampleBuffer], audio: [CMSampleBuffer]) {
    let samples = SendableMuxedSamples(video: video, audio: audio)
    queue.async { [self] in
      guard !isFinishing, storedFailure == nil else { return }
      let video = samples.video.compactMap(Self.pendingVideoSample)
      let audio = samples.audio.compactMap(Self.pendingAudioSample)
      pending.append(contentsOf: video)
      pending.append(contentsOf: audio)
      latestVideoTime = Self.latestTime(current: latestVideoTime, samples: video)
      latestAudioTime = Self.latestTime(current: latestAudioTime, samples: audio)
      pending.sort(by: Self.precedes)
      drain()
      scheduleDrainIfNeeded()
    }
  }

  public func finish(
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    queue.async { [self] in
      guard !isFinishing else {
        completionHandler(.success(()))
        return
      }
      isFinishing = true
      if let storedFailure {
        completionHandler(.failure(storedFailure))
        return
      }
      finishHandler = completionHandler
      finishWhenDrained()
    }
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
    while let sample = pending.first {
      guard canDrain(sample) else { return }
      guard hasStartedAtSyncVideo || sample.isSyncVideo else {
        // Before the first random-access frame, neither AAC nor inter-frame
        // H.264 is independently decodable. Drop that bounded prefix and
        // continue waiting for the next sync sample.
        pending.removeFirst()
        continue
      }
      let input = sample.track == .video ? videoInput : audioInput
      guard input.isReadyForMoreMediaData else { return }

      if sample.isSyncVideo, shouldFlush(before: sample.sortTime) {
        assetWriter.flushSegment()
        segmentStartTime = sample.sortTime
      }
      guard input.append(sample.buffer) else {
        fail(Self.writerError(assetWriter.error, fallback: "append failed"))
        return
      }
      hasAppendedSample = true
      if segmentStartTime == nil, sample.isSyncVideo {
        segmentStartTime = sample.sortTime
      }
      if sample.isSyncVideo {
        hasStartedAtSyncVideo = true
      }
      pending.removeFirst()
    }
  }

  private func shouldFlush(before syncTime: CMTime) -> Bool {
    guard hasAppendedSample, let segmentStartTime else { return false }
    return CMTimeCompare(CMTimeSubtract(syncTime, segmentStartTime), targetSegmentDuration) >= 0
  }

  private func scheduleDrainIfNeeded() {
    guard let first = pending.first, canDrain(first), !isDrainScheduled, storedFailure == nil
    else { return }
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
      fail(Self.writerError(assetWriter.error, fallback: "writer stopped before drain"))
      return
    }
    drain()
    guard pending.isEmpty else {
      scheduleDrainIfNeeded()
      return
    }
    self.finishHandler = nil
    videoInput.markAsFinished()
    audioInput.markAsFinished()
    assetWriter.finishWriting { [self] in
      queue.async {
        if self.assetWriter.status == .failed {
          let error = Self.writerError(self.assetWriter.error, fallback: "finish failed")
          self.fail(error)
          finishHandler(.failure(error))
        } else {
          finishHandler(.success(()))
        }
      }
    }
  }

  private func fail(_ error: Error) {
    guard storedFailure == nil else { return }
    storedFailure = error
    pending.removeAll()
    assetWriter.cancelWriting()
    onFailure(error)
    if let finishHandler {
      self.finishHandler = nil
      finishHandler(.failure(error))
    }
  }

  private static func pendingVideoSample(_ buffer: CMSampleBuffer) -> PendingSample? {
    guard CMSampleBufferDataIsReady(buffer), buffer.presentationTimeStamp.isValid else { return nil }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
      as? [[CFString: Any]]
    let isSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
    return PendingSample(
      track: .video,
      buffer: buffer,
      isSyncVideo: isSync,
      sortTime: buffer.decodeTimeStamp.isValid ? buffer.decodeTimeStamp : buffer.presentationTimeStamp)
  }

  private static func pendingAudioSample(_ buffer: CMSampleBuffer) -> PendingSample? {
    guard CMSampleBufferDataIsReady(buffer), buffer.presentationTimeStamp.isValid else { return nil }
    return PendingSample(
      track: .audio,
      buffer: buffer,
      isSyncVideo: false,
      sortTime: buffer.presentationTimeStamp)
  }

  private static func precedes(_ lhs: PendingSample, _ rhs: PendingSample) -> Bool {
    let comparison = CMTimeCompare(lhs.sortTime, rhs.sortTime)
    if comparison != 0 { return comparison < 0 }
    if lhs.isSyncVideo != rhs.isSyncVideo { return lhs.isSyncVideo }
    return lhs.track == .video && rhs.track == .audio
  }

  private func canDrain(_ sample: PendingSample) -> Bool {
    if isFinishing { return true }
    guard let latestVideoTime, let latestAudioTime else { return false }
    let watermark = CMTimeMinimum(latestVideoTime, latestAudioTime)
    return CMTimeCompare(sample.sortTime, watermark) <= 0
  }

  private static func latestTime(
    current: CMTime?, samples: [PendingSample]
  ) -> CMTime? {
    samples.reduce(current) { latest, sample in
      guard let latest else { return sample.sortTime }
      return CMTimeMaximum(latest, sample.sortTime)
    }
  }

  private static func writerError(_ error: Error) -> MuxedPassthroughSegmentedMP4WriterError {
    writerError(error as NSError, fallback: error.localizedDescription)
  }

  private static func writerError(
    _ error: Error?, fallback: String
  ) -> MuxedPassthroughSegmentedMP4WriterError {
    guard let error = error as NSError? else { return .writerFailed(fallback) }
    return .writerFailed(
      "domain=\(error.domain) code=\(error.code) description=\(error.localizedDescription) userInfo=\(error.userInfo)")
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

private struct SendableMuxedSamples: @unchecked Sendable {
  var video: [CMSampleBuffer]
  var audio: [CMSampleBuffer]
}
