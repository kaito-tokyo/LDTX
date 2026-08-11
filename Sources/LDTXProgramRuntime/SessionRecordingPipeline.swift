// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXMP4
import LDTXRecording
import OSLog

/// Writes the H.264 Main Program and AAC Main Mix into one fragmented MP4.
final class SessionRecordingPipeline: @unchecked Sendable {
  private static let maximumPendingVideoDuration = CMTime(seconds: 30, preferredTimescale: 600)
  private static let maximumPendingVideoSampleCount = 3_600
  private let logger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "SessionRecording"
  )
  private let lock = NSLock()
  private let mainTrack: HLSByteRangeTrackRecorder
  private let startNumber: Int
  private let timelineNormalizer: RecordingTimelineNormalizer
  private let failureHandler: @Sendable (Error) -> Void
  private var writer: MuxedPassthroughSegmentedMP4Writer?
  private var audioEncoder: AACAudioEncoder?
  private var firstVideo: CMSampleBuffer?
  private var pendingVideo: [CMSampleBuffer] = []
  private var pendingVideoMinimumPTS: CMTime?
  private var pendingVideoMaximumPTS: CMTime?
  private var pendingAudio: [CMSampleBuffer] = []
  private var hasReceivedAudioSample = false
  private var storedFailure: Error?
  private var isFinishing = false

  init(
    package: HLSByteRangeRecordingPackage,
    canvas: RecordingCanvas = .landscape,
    targetSegmentDurationSeconds _: Int,
    startNumber: Int,
    timelineNormalizer: RecordingTimelineNormalizer,
    failureHandler: @escaping @Sendable (Error) -> Void
  ) throws {
    guard let track = package.canvasTracks[canvas] else {
      throw HLSByteRangeRecordingPackageError.missingTrack(canvas.rawValue)
    }
    mainTrack = track
    self.startNumber = startNumber
    self.timelineNormalizer = timelineNormalizer
    self.failureHandler = failureHandler
  }

  func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    timelineNormalizer.submit(sampleBuffer, trackID: "main-video") { [weak self] normalized in
      self?.appendNormalizedVideo(normalized)
    }
  }

  func appendFirstVideo(
    _ sampleBuffer: CMSampleBuffer,
    mainAudioFormatDescription: CMAudioFormatDescription? = nil
  ) throws {
    guard let normalized = timelineNormalizer.normalized(sampleBuffer) else {
      throw SessionRecordingPipelineError.cannotNormalizeFirstVideo
    }
    try lock.withLock {
      guard !isFinishing, storedFailure == nil else { return }
      if let mainAudioFormatDescription, audioEncoder == nil {
        do {
          audioEncoder = try AACAudioEncoder(
            inputFormatDescription: mainAudioFormatDescription)
        } catch {
          failLocked(error)
          throw error
        }
      }
      firstVideo = normalized
      mainTrack.notePresentationStart(normalized.presentationTimeStamp)
      pendingVideo.append(normalized)
      pendingVideoMinimumPTS = normalized.presentationTimeStamp
      pendingVideoMaximumPTS = normalized.presentationTimeStamp
      createWriterIfPossibleLocked()
      if mainAudioFormatDescription != nil, writer == nil {
        throw storedFailure ?? SessionRecordingPipelineError.incompleteMainProgram
      }
      drainPendingSamplesLocked()
    }
  }

  func appendAudio(_ sampleBuffer: CMSampleBuffer) {
    timelineNormalizer.submit(sampleBuffer, trackID: "main-audio") { [weak self] normalized in
      self?.appendNormalizedAudio(normalized)
    }
  }

  func finish(completionHandler: @escaping @Sendable () -> Void) {
    let writer: MuxedPassthroughSegmentedMP4Writer? = lock.withLock {
      guard !isFinishing else { return nil }
      isFinishing = true
      do {
        if storedFailure == nil, let audioEncoder {
          pendingAudio.append(contentsOf: try audioEncoder.finish())
        }
        if storedFailure == nil, !hasReceivedAudioSample {
          throw SessionRecordingPipelineError.incompleteMainProgram
        }
        if storedFailure == nil {
          createWriterIfPossibleLocked()
          drainPendingSamplesLocked()
        }
      } catch {
        failLocked(error)
      }
      return self.writer
    }
    timelineNormalizer.finish()
    guard let writer else {
      let error = lock.withLock {
        storedFailure ?? SessionRecordingPipelineError.incompleteMainProgram
      }
      markFailed(error)
      completionHandler()
      return
    }
    writer.finish { [weak self] result in
      if case .failure(let error) = result { self?.markFailed(error) }
      completionHandler()
    }
  }

  private func appendNormalizedVideo(_ sampleBuffer: CMSampleBuffer) {
    lock.withLock {
      guard !isFinishing, storedFailure == nil else { return }
      if firstVideo == nil { firstVideo = sampleBuffer }
      mainTrack.notePresentationStart(sampleBuffer.presentationTimeStamp)
      pendingVideo.append(sampleBuffer)
      updatePendingVideoRangeLocked(with: sampleBuffer.presentationTimeStamp)
      guard validatePendingVideoLocked() else { return }
      createWriterIfPossibleLocked()
      drainPendingSamplesLocked()
    }
  }

  private func appendNormalizedAudio(_ sampleBuffer: CMSampleBuffer) {
    lock.withLock {
      guard !isFinishing, storedFailure == nil else { return }
      do {
        hasReceivedAudioSample = true
        if audioEncoder == nil {
          guard let format = sampleBuffer.formatDescription else {
            throw SessionRecordingPipelineError.missingAudioFormat
          }
          audioEncoder = try AACAudioEncoder(inputFormatDescription: format)
        }
        let encoded = try audioEncoder?.encode(sampleBuffer) ?? []
        pendingAudio.append(contentsOf: encoded)
        createWriterIfPossibleLocked()
        drainPendingSamplesLocked()
      } catch {
        failLocked(error)
      }
    }
  }

  private func createWriterIfPossibleLocked() {
    guard storedFailure == nil,
      writer == nil,
      let videoFormat = firstVideo?.formatDescription,
      let audioFormat = audioEncoder?.outputFormatDescription
    else { return }
    do {
      let pipeline = WeakSessionRecordingPipeline()
      let writer = try MuxedPassthroughSegmentedMP4Writer(
        videoFormatDescription: videoFormat,
        audioFormatDescription: audioFormat,
        startNumber: startNumber,
        onFailure: { error in pipeline.value?.markFailed(error) },
        onSegment: { segment in pipeline.value?.write(segment) }
      )
      pipeline.value = self
      self.writer = writer
    } catch {
      failLocked(error)
    }
  }

  private func validatePendingVideoLocked() -> Bool {
    guard writer == nil else { return true }
    guard pendingVideo.count <= Self.maximumPendingVideoSampleCount else {
      failLocked(SessionRecordingPipelineError.pendingMainMixExceededLimit)
      return false
    }
    guard
      let minimumPTS = pendingVideoMinimumPTS,
      let maximumPTS = pendingVideoMaximumPTS,
      maximumPTS - minimumPTS <= Self.maximumPendingVideoDuration
    else {
      failLocked(SessionRecordingPipelineError.pendingMainMixExceededLimit)
      return false
    }
    return true
  }

  private func updatePendingVideoRangeLocked(with presentationTimeStamp: CMTime) {
    guard presentationTimeStamp.isNumeric else {
      failLocked(SessionRecordingPipelineError.pendingMainMixExceededLimit)
      return
    }
    if pendingVideoMinimumPTS.map({ presentationTimeStamp < $0 }) ?? true {
      pendingVideoMinimumPTS = presentationTimeStamp
    }
    if pendingVideoMaximumPTS.map({ presentationTimeStamp > $0 }) ?? true {
      pendingVideoMaximumPTS = presentationTimeStamp
    }
  }

  private func drainPendingSamplesLocked() {
    guard let writer, !pendingVideo.isEmpty || !pendingAudio.isEmpty else { return }
    writer.append(video: pendingVideo, audio: pendingAudio)
    pendingVideo.removeAll(keepingCapacity: true)
    pendingVideoMinimumPTS = nil
    pendingVideoMaximumPTS = nil
    pendingAudio.removeAll(keepingCapacity: true)
  }

  private func write(_ segment: SegmentedMP4Segment) {
    do { try mainTrack.write(segment) } catch { markFailed(error) }
  }

  private func markFailed(_ error: Error) {
    lock.withLock { failLocked(error) }
  }

  private func failLocked(_ error: Error) {
    guard storedFailure == nil else { return }
    storedFailure = error
    pendingVideo.removeAll(keepingCapacity: false)
    pendingAudio.removeAll(keepingCapacity: false)
    mainTrack.markFailed(error)
    logger.error("Main recording write failed: \(error.localizedDescription, privacy: .public)")
    failureHandler(error)
  }
}

private final class WeakSessionRecordingPipeline: @unchecked Sendable {
  weak var value: SessionRecordingPipeline?
}

enum SessionRecordingPipelineError: Error, LocalizedError {
  case cannotNormalizeFirstVideo
  case missingAudioFormat
  case incompleteMainProgram
  case pendingMainMixExceededLimit

  var errorDescription: String? {
    switch self {
    case .cannotNormalizeFirstVideo:
      "The first recording video sample could not be normalized."
    case .missingAudioFormat:
      "The Main Mix has no audio format description."
    case .incompleteMainProgram:
      "The Main Program did not receive both video and audio before finalization."
    case .pendingMainMixExceededLimit:
      "The Main Mix did not start before the pending video buffer reached its limit."
    }
  }
}
