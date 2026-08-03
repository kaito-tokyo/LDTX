// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import OSLog

private let muxedPassthroughSegmentLogger = Logger(
  subsystem: "tokyo.kaito.ldtx", category: "DASHSegment")

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
  private let onSegment: SegmentHandler
  private let onFailure: @Sendable (any Error) -> Void
  private let queue = DispatchQueue(
    label: "tokyo.kaito.ldtx.MuxedPassthroughSegmentedMP4Writer")
  private var pending: [PendingSample] = []
  private var currentSegmentDiagnostics = SegmentedMP4SegmentDiagnostics()
  private var pendingSegmentDiagnostics: [SegmentedMP4SegmentDiagnostics] = []
  private var lastSyncVideoTime: CMTime?
  private var nextSegmentNumber: Int
  private var segmentStartTime: CMTime?
  private var latestVideoTime: CMTime?
  private var latestAudioTime: CMTime?
  private var hasAppendedSample = false
  private var isFinishing = false
  private var isDrainScheduled = false
  private var storedFailure: (any Error)?
  private var finishHandler: (@Sendable (Result<Void, any Error>) -> Void)?

  public init(
    videoFormatDescription: CMVideoFormatDescription,
    audioFormatDescription: CMAudioFormatDescription,
    startNumber: Int = 1,
    onFailure: @escaping @Sendable (any Error) -> Void = { _ in },
    onSegment: @escaping SegmentHandler
  ) throws {
    guard startNumber > 0 else {
      throw MuxedPassthroughSegmentedMP4WriterError.invalidConfiguration
    }
    guard CMFormatDescriptionGetMediaSubType(videoFormatDescription) == kCMVideoCodecType_H264
    else { throw MuxedPassthroughSegmentedMP4WriterError.invalidVideoFormat }
    guard CMFormatDescriptionGetMediaSubType(audioFormatDescription) == kAudioFormatMPEG4AAC
    else { throw MuxedPassthroughSegmentedMP4WriterError.invalidAudioFormat }

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
        let diagnostics = pendingSegmentDiagnostics.isEmpty
          ? nil : pendingSegmentDiagnostics.removeFirst()
        let durationSeconds = Self.durationSeconds(from: segmentReport)
        let earliestPresentationTimeSeconds = Self.earliestPresentationTimeSeconds(
          from: segmentReport)
        let startMilliseconds = Self.milliseconds(earliestPresentationTimeSeconds)
        let durationMilliseconds = Self.milliseconds(durationSeconds)
        let maximumSyncIntervalMilliseconds = Self.milliseconds(
          diagnostics?.maximumSyncVideoIntervalSeconds)
        muxedPassthroughSegmentLogger.info(
          "[event:dash.segment.generated] segment=\(number, privacy: .public) startMs=\(startMilliseconds, privacy: .public) durationMs=\(durationMilliseconds, privacy: .public) bytes=\(segmentData.count, privacy: .public) videoSamples=\(diagnostics?.videoSampleCount ?? -1, privacy: .public) audioSamples=\(diagnostics?.audioSampleCount ?? -1, privacy: .public) audioFrames=\(diagnostics?.audioFrameCount ?? -1, privacy: .public) syncSamples=\(diagnostics?.syncVideoSampleCount ?? -1, privacy: .public) maxSyncGapMs=\(maximumSyncIntervalMilliseconds, privacy: .public)"
        )
        logBoundaryDiagnostics(
          segmentNumber: number,
          durationMilliseconds: durationMilliseconds,
          diagnostics: diagnostics,
          maximumSyncIntervalMilliseconds: maximumSyncIntervalMilliseconds)
        onSegment(SegmentedMP4Segment(
          kind: .media(number: number),
          data: segmentData,
          durationSeconds: durationSeconds,
          earliestPresentationTimeSeconds: earliestPresentationTimeSeconds,
          diagnostics: diagnostics))
      @unknown default:
        break
      }
    }
  }

  private func drain() {
    guard assetWriter.status == .writing else { return }
    while let sample = pending.first {
      guard canDrain(sample) else { return }
      let input = sample.track == .video ? videoInput : audioInput
      guard input.isReadyForMoreMediaData else { return }

      if sample.isSyncVideo, hasAppendedSample, segmentStartTime != nil {
        recordSyncVideoInterval(endingAt: sample.sortTime)
        pendingSegmentDiagnostics.append(currentSegmentDiagnostics)
        currentSegmentDiagnostics = SegmentedMP4SegmentDiagnostics()
        lastSyncVideoTime = nil
        assetWriter.flushSegment()
        segmentStartTime = sample.sortTime
      }
      guard input.append(sample.buffer) else {
        fail(Self.writerError(assetWriter.error, fallback: "append failed"))
        return
      }
      hasAppendedSample = true
      recordDiagnostics(for: sample)
      if segmentStartTime == nil, sample.isSyncVideo {
        segmentStartTime = sample.sortTime
      }
      pending.removeFirst()
    }
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
    if currentSegmentDiagnostics.videoSampleCount > 0
      || currentSegmentDiagnostics.audioSampleCount > 0
    {
      pendingSegmentDiagnostics.append(currentSegmentDiagnostics)
      currentSegmentDiagnostics = SegmentedMP4SegmentDiagnostics()
      lastSyncVideoTime = nil
    }
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

  private func recordDiagnostics(for sample: PendingSample) {
    switch sample.track {
    case .video:
      currentSegmentDiagnostics.videoSampleCount += CMSampleBufferGetNumSamples(sample.buffer)
      guard sample.isSyncVideo else { return }
      currentSegmentDiagnostics.syncVideoSampleCount += 1
      recordSyncVideoInterval(endingAt: sample.sortTime)
      lastSyncVideoTime = sample.sortTime
    case .audio:
      currentSegmentDiagnostics.audioSampleCount += 1
      currentSegmentDiagnostics.audioFrameCount += CMSampleBufferGetNumSamples(sample.buffer)
    }
  }

  private func recordSyncVideoInterval(endingAt time: CMTime) {
    guard let lastSyncVideoTime else { return }
    let interval = CMTimeSubtract(time, lastSyncVideoTime).seconds
    guard interval.isFinite, interval >= 0 else { return }
    currentSegmentDiagnostics.maximumSyncVideoIntervalSeconds = max(
      currentSegmentDiagnostics.maximumSyncVideoIntervalSeconds ?? 0,
      interval)
  }

  private func logBoundaryDiagnostics(
    segmentNumber: Int,
    durationMilliseconds: Int64,
    diagnostics: SegmentedMP4SegmentDiagnostics?,
    maximumSyncIntervalMilliseconds: Int64
  ) {
    if diagnostics?.syncVideoSampleCount != 1 {
      muxedPassthroughSegmentLogger.error(
        "[event:dash.segment.invalid-boundary] segment=\(segmentNumber, privacy: .public) durationMs=\(durationMilliseconds, privacy: .public) syncSamples=\(diagnostics?.syncVideoSampleCount ?? -1, privacy: .public)"
      )
    }
    if durationMilliseconds >= 8_000 || maximumSyncIntervalMilliseconds >= 8_000 {
      muxedPassthroughSegmentLogger.error(
        "[event:dash.segment.gop-contract-violation] segment=\(segmentNumber, privacy: .public) durationMs=\(durationMilliseconds, privacy: .public) maxSyncGapMs=\(maximumSyncIntervalMilliseconds, privacy: .public)"
      )
    } else if durationMilliseconds > 4_000 || maximumSyncIntervalMilliseconds > 4_000 {
      muxedPassthroughSegmentLogger.warning(
        "[event:dash.segment.long] segment=\(segmentNumber, privacy: .public) durationMs=\(durationMilliseconds, privacy: .public) maxSyncGapMs=\(maximumSyncIntervalMilliseconds, privacy: .public)"
      )
    } else if durationMilliseconds >= 0 && durationMilliseconds < 1_000 {
      muxedPassthroughSegmentLogger.notice(
        "[event:dash.segment.short] segment=\(segmentNumber, privacy: .public) durationMs=\(durationMilliseconds, privacy: .public)"
      )
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

  private static func milliseconds(_ seconds: Double?) -> Int64 {
    guard let seconds, seconds.isFinite else { return -1 }
    return Int64(clamping: Int((seconds * 1_000).rounded()))
  }
}

private struct SendableMuxedSamples: @unchecked Sendable {
  var video: [CMSampleBuffer]
  var audio: [CMSampleBuffer]
}
