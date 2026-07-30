// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXMP4
import LDTXOutputMedia
import OSLog

/// In-process implementation of the Main Program recording contract.
///
/// This is deliberately a muxed writer, not the legacy pair of video and audio
/// files.  It is used when the Main Recording XPC is unavailable (for example
/// in a unit-test host); production sends these same compressed samples to the
/// XPC writer instead.
final class SeparatedProgramRecordingPipeline: @unchecked Sendable {
  private let logger = Logger(subsystem: "tokyo.kaito.ldtx", category: "MainProgramRecording")
  private let lock = NSLock()
  private let track: HLSByteRangeTrackRecorder
  private let segmentDurationSeconds: Int
  private let startNumber: Int
  private let timelineNormalizer: RecordingTimelineNormalizer
  private let failureHandler: @Sendable (Error) -> Void
  private var writer: MuxedPassthroughSegmentedMP4Writer?
  private var firstVideo: CMSampleBuffer?
  private var pendingVideo: [CMSampleBuffer] = []
  private var pendingAudio: [CMSampleBuffer] = []
  private var isFinishing = false

  init(
    package: HLSByteRangeRecordingPackage,
    segmentDurationSeconds: Int,
    startNumber: Int,
    timelineNormalizer: RecordingTimelineNormalizer,
    failureHandler: @escaping @Sendable (Error) -> Void
  ) throws {
    track = package.mainTrack
    self.segmentDurationSeconds = segmentDurationSeconds
    self.startNumber = startNumber
    self.timelineNormalizer = timelineNormalizer
    self.failureHandler = failureHandler
  }

  func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    timelineNormalizer.submit(sampleBuffer, trackID: "main-video") { [weak self] normalized in
      self?.appendNormalizedVideo(normalized)
    }
  }

  func appendProgramAudio(_ packet: ProgramOutputAACPacket) {
    do {
      let sampleBuffer = try ProgramOutputMediaSampleConverter.makeAACSample(
        accessUnit: packet.accessUnit, format: packet.format)
      appendCompressedAudio(sampleBuffer)
    } catch {
      markFailed(error)
    }
  }

  private func appendCompressedAudio(_ sampleBuffer: CMSampleBuffer) {
    timelineNormalizer.submit(sampleBuffer, trackID: "main-audio") { [weak self] normalized in
      self?.appendNormalizedAudio(normalized)
    }
  }

  func finish(completionHandler: @escaping @Sendable () -> Void) {
    let writer: MuxedPassthroughSegmentedMP4Writer? = lock.withLock {
      guard !isFinishing else { return nil }
      isFinishing = true
      createWriterIfPossibleLocked()
      let writer = self.writer
      if let writer {
        writer.append(video: pendingVideo, audio: pendingAudio)
        pendingVideo.removeAll(keepingCapacity: false)
        pendingAudio.removeAll(keepingCapacity: false)
      }
      return writer
    }
    timelineNormalizer.finish()
    guard let writer else { completionHandler(); return }
    writer.finish { [weak self] result in
      if case .failure(let error) = result { self?.markFailed(error) }
      completionHandler()
    }
  }

  private func appendNormalizedVideo(_ sampleBuffer: CMSampleBuffer) {
    lock.withLock {
      guard !isFinishing else { return }
      track.notePresentationStart(sampleBuffer.presentationTimeStamp)
      if firstVideo == nil { firstVideo = sampleBuffer }
      createWriterIfPossibleLocked()
      if let writer { writer.append(video: [sampleBuffer], audio: []) }
      else { pendingVideo.append(sampleBuffer) }
    }
  }

  private func appendNormalizedAudio(_ sampleBuffer: CMSampleBuffer) {
    lock.withLock {
      guard !isFinishing else { return }
      createWriterIfPossibleLocked()
      if let writer { writer.append(video: [], audio: [sampleBuffer]) }
      else { pendingAudio.append(sampleBuffer) }
    }
  }

  private func createWriterIfPossibleLocked() {
    guard writer == nil, let video = firstVideo,
      let videoFormat = video.formatDescription,
      let audioFormat = pendingAudio.first?.formatDescription
    else { return }
    do {
      let pipeline = WeakMainProgramRecordingPipeline()
      let writer = try MuxedPassthroughSegmentedMP4Writer(
        videoFormatDescription: videoFormat,
        audioFormatDescription: audioFormat,
        segmentDurationSeconds: segmentDurationSeconds,
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

  private func write(_ segment: SegmentedMP4Segment) {
    do { try track.write(segment) }
    catch { markFailed(error) }
  }

  private func markFailed(_ error: Error) {
    lock.withLock { failLocked(error) }
  }

  private func failLocked(_ error: Error) {
    track.markFailed(error)
    logger.error("Main recording write failed: \(error.localizedDescription, privacy: .public)")
    failureHandler(error)
  }
}

private final class WeakMainProgramRecordingPipeline: @unchecked Sendable {
  weak var value: SeparatedProgramRecordingPipeline?
}
