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
  private var latestVideoInitializationSegment: SegmentedMP4Segment?
  private var failureHandler: @Sendable (Error) -> Void
  private let mediaSegmentHandler: @Sendable () -> Void

  init(
    package: HLSByteRangeRecordingPackage,
    segmentDurationSeconds: Int,
    startNumber: Int,
    failureHandler: @escaping @Sendable (Error) -> Void,
    mediaSegmentHandler: @escaping @Sendable () -> Void = {}
  ) throws {
    guard let mainAudioTrack = package.audioTracks[Self.mainAudioTrackID] else {
      throw SeparatedProgramRecordingError.missingMainAudioTrack
    }
    videoTrack = package.mainTrack
    self.failureHandler = failureHandler
    self.mediaSegmentHandler = mediaSegmentHandler
    audioRecorder = try AudioSideStreamRecorder(
      trackRecorder: mainAudioTrack,
      segmentDurationSeconds: segmentDurationSeconds
    )

    let pipeline = WeakSeparatedProgramRecordingPipeline()
    videoWriter = try H264PassthroughSegmentedMP4Writer(
      segmentDurationSeconds: segmentDurationSeconds,
      startNumber: startNumber,
      onFailure: failureHandler
    ) { segment in
      pipeline.value?.writeVideo(segment)
    }
    pipeline.value = self
  }

  func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    videoWriter.append(sampleBuffer)
  }

  func appendAudio(_ sampleBuffer: CMSampleBuffer) {
    audioRecorder.append(sampleBuffer)
  }

  func rotate(to package: HLSByteRangeRecordingPackage) throws {
    guard let mainAudioTrack = package.audioTracks[Self.mainAudioTrackID] else {
      throw SeparatedProgramRecordingError.missingMainAudioTrack
    }
    try lock.withLock {
      videoTrack = package.mainTrack
      if let latestVideoInitializationSegment {
        try videoTrack.write(latestVideoInitializationSegment)
      }
    }
    try audioRecorder.rotate(to: mainAudioTrack)
  }

  func finish(completionHandler: @escaping @Sendable () -> Void) {
    let group = DispatchGroup()
    group.enter()
    videoWriter.finish { _ in group.leave() }
    group.enter()
    audioRecorder.finish {
      group.leave()
    }
    group.notify(queue: .global(), execute: completionHandler)
  }

  private func writeVideo(_ segment: SegmentedMP4Segment) {
    do {
      try lock.withLock {
        if case .initialization = segment.kind {
          latestVideoInitializationSegment = segment
        }
        try videoTrack.write(segment)
      }
      if case .media = segment.kind { mediaSegmentHandler() }
    } catch {
      logger.error("Separated recording video write failed: \(error.localizedDescription)")
      failureHandler(error)
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
