// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXYouTubeOutputProtocol

enum YouTubeOutputMediaBacklogError: Error, Equatable, Sendable {
  case videoLimitExceeded
  case audioLimitExceeded
  case durationLimitExceeded
}

/// Bounded, lossless backlog behind the Workspace media channel. Reaching a
/// limit is terminal for this YouTube service pair; accepted media is never
/// discarded to make room for newer samples.
struct YouTubeOutputMediaBacklog: Sendable {
  struct Batch: Sendable {
    var videoFormat: YouTubeOutputH264Format?
    var video: [YouTubeOutputH264AccessUnit]
    var audio: [YouTubeOutputPCMBuffer]
  }

  let maximumVideoCount: Int
  let maximumAudioCount: Int
  private(set) var video: [YouTubeOutputH264AccessUnit] = []
  private(set) var audio: [YouTubeOutputPCMBuffer] = []
  private(set) var videoFormat: YouTubeOutputH264Format?
  private let clock = ContinuousClock()
  private var oldestEnqueueInstant: ContinuousClock.Instant?

  init(maximumVideoCount: Int = 10_000, maximumAudioCount: Int = 10_000) {
    precondition(maximumVideoCount > 0 && maximumAudioCount > 0)
    self.maximumVideoCount = maximumVideoCount
    self.maximumAudioCount = maximumAudioCount
  }

  var count: Int { video.count + audio.count }
  var isEmpty: Bool { video.isEmpty && audio.isEmpty }

  mutating func appendVideo(
    _ accessUnit: YouTubeOutputH264AccessUnit,
    format: YouTubeOutputH264Format?
  ) throws {
    try checkDurationLimit()
    guard video.count < maximumVideoCount else {
      throw YouTubeOutputMediaBacklogError.videoLimitExceeded
    }
    if let format { videoFormat = format }
    video.append(accessUnit)
    if oldestEnqueueInstant == nil { oldestEnqueueInstant = clock.now }
  }

  mutating func appendAudio(_ buffer: YouTubeOutputPCMBuffer) throws {
    try checkDurationLimit()
    guard audio.count < maximumAudioCount else {
      throw YouTubeOutputMediaBacklogError.audioLimitExceeded
    }
    audio.append(buffer)
    if oldestEnqueueInstant == nil { oldestEnqueueInstant = clock.now }
  }

  mutating func takeBatch() -> Batch? {
    guard !isEmpty else { return nil }
    defer {
      videoFormat = nil
      video.removeAll(keepingCapacity: true)
      audio.removeAll(keepingCapacity: true)
      oldestEnqueueInstant = nil
    }
    return Batch(videoFormat: videoFormat, video: video, audio: audio)
  }

  private func checkDurationLimit() throws {
    guard let oldestEnqueueInstant else { return }
    guard clock.now - oldestEnqueueInstant < .seconds(30) else {
      throw YouTubeOutputMediaBacklogError.durationLimitExceeded
    }
  }
}
