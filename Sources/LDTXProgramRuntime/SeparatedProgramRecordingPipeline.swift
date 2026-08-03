// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXMP4
import OSLog

final class SeparatedProgramRecordingPipeline: @unchecked Sendable {
  static let mainAudioTrackID = "main-mix"

  private let logger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "SeparatedProgramRecording"
  )
  private let lock = NSLock()
  private let videoWriter: H264PassthroughSegmentedMP4Writer
  private let audioRecorder: AudioSideStreamRecorder
  private var videoTrack: HLSByteRangeTrackRecorder
  private var failureHandler: @Sendable (Error) -> Void
  private let timelineNormalizer: RecordingTimelineNormalizer

  init(
    package: HLSByteRangeRecordingPackage,
    targetSegmentDurationSeconds: Int,
    startNumber: Int,
    timelineNormalizer: RecordingTimelineNormalizer,
    failureHandler: @escaping @Sendable (Error) -> Void
  ) throws {
    guard let mainAudioTrack = package.audioTracks[Self.mainAudioTrackID] else {
      throw SeparatedProgramRecordingError.missingMainAudioTrack
    }
    videoTrack = package.mainTrack
    self.failureHandler = failureHandler
    self.timelineNormalizer = timelineNormalizer
    audioRecorder = try AudioSideStreamRecorder(
      trackRecorder: mainAudioTrack,
      targetSegmentDurationSeconds: targetSegmentDurationSeconds,
      timelineNormalizer: timelineNormalizer,
      timelineTrackID: Self.mainAudioTrackID
    )

    let pipeline = WeakSeparatedProgramRecordingPipeline()
    videoWriter = try H264PassthroughSegmentedMP4Writer(
      targetSegmentDurationSeconds: targetSegmentDurationSeconds,
      startNumber: startNumber,
      onFailure: { error in
        if let value = pipeline.value {
          value.handleVideoFailure(error)
        } else {
          failureHandler(error)
        }
      }
    ) { segment in
      pipeline.value?.writeVideo(segment)
    }
    pipeline.value = self
  }

  func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    timelineNormalizer.submit(sampleBuffer, trackID: "output-video") { [weak self, videoWriter] normalized in
      self?.noteVideoPresentationStart(normalized.presentationTimeStamp)
      videoWriter.append(normalized)
    }
  }

  private func noteVideoPresentationStart(_ presentationTime: CMTime) {
    lock.withLock {
      videoTrack.notePresentationStart(presentationTime)
    }
  }

  func appendAudio(_ sampleBuffer: CMSampleBuffer) {
    audioRecorder.append(sampleBuffer)
  }

  func finish(completionHandler: @escaping @Sendable () -> Void) {
    timelineNormalizer.finish()
    let group = DispatchGroup()
    group.enter()
    videoWriter.finish { [weak self] result in
      if case .failure(let error) = result {
        self?.markVideoTrackFailed(error)
      }
      group.leave()
    }
    group.enter()
    audioRecorder.finish {
      group.leave()
    }
    group.notify(queue: .global(), execute: completionHandler)
  }

  private func writeVideo(_ segment: SegmentedMP4Segment) {
    do {
      try lock.withLock {
        try videoTrack.write(segment)
      }
    } catch {
      logger.error("Separated recording video write failed: \(error.localizedDescription)")
      failureHandler(error)
    }
  }

  private func handleVideoFailure(_ error: any Error) {
    markVideoTrackFailed(error)
    failureHandler(error)
  }

  private func markVideoTrackFailed(_ error: any Error) {
    lock.withLock {
      videoTrack.markFailed(error)
    }
  }
}

private final class WeakSeparatedProgramRecordingPipeline: @unchecked Sendable {
  weak var value: SeparatedProgramRecordingPipeline?
}

enum SeparatedProgramRecordingError: Error, LocalizedError {
  case missingMainAudioTrack

  var errorDescription: String? {
    switch self {
    case .missingMainAudioTrack:
      "The recording package does not contain its main audio rendition."
    }
  }
}
