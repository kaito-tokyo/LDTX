// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXYouTubeOutputProtocol

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
  private var requiresKeyFrame = false
  private var minimumAudioTime: YouTubeOutputMediaTime?

  init(maximumVideoCount: Int = 120, maximumAudioCount: Int = 256) {
    self.maximumVideoCount = maximumVideoCount
    self.maximumAudioCount = maximumAudioCount
  }

  var count: Int { video.count + audio.count }
  var isEmpty: Bool { video.isEmpty && audio.isEmpty }

  mutating func appendVideo(
    _ accessUnit: YouTubeOutputH264AccessUnit,
    format: YouTubeOutputH264Format?
  ) {
    if let format { videoFormat = format }
    if requiresKeyFrame {
      guard accessUnit.isKeyFrame else { return }
      requiresKeyFrame = false
      minimumAudioTime = accessUnit.presentationTime
      video = [accessUnit]
      return
    }
    video.append(accessUnit)
    if video.count > maximumVideoCount {
      video.removeAll(keepingCapacity: true)
      audio.removeAll(keepingCapacity: true)
      if accessUnit.isKeyFrame {
        minimumAudioTime = accessUnit.presentationTime
        video.append(accessUnit)
      } else {
        requiresKeyFrame = true
        minimumAudioTime = nil
      }
    }
  }

  mutating func appendAudio(_ buffer: YouTubeOutputPCMBuffer) {
    guard !requiresKeyFrame else { return }
    if let minimumAudioTime, Self.compare(buffer.presentationTime, minimumAudioTime) < 0 {
      return
    }
    audio.append(buffer)
    if audio.count > maximumAudioCount {
      audio.removeFirst(audio.count - maximumAudioCount)
    }
  }

  mutating func takeBatch() -> Batch? {
    guard !isEmpty else { return nil }
    defer {
      videoFormat = nil
      minimumAudioTime = nil
      video.removeAll(keepingCapacity: true)
      audio.removeAll(keepingCapacity: true)
    }
    return Batch(videoFormat: videoFormat, video: video, audio: audio)
  }

  private static func compare(_ lhs: YouTubeOutputMediaTime, _ rhs: YouTubeOutputMediaTime) -> Int {
    guard lhs.timescale > 0, rhs.timescale > 0 else {
      return lhs.value == rhs.value ? 0 : (lhs.value < rhs.value ? -1 : 1)
    }
    let lhsSeconds = Double(lhs.value) / Double(lhs.timescale)
    let rhsSeconds = Double(rhs.value) / Double(rhs.timescale)
    if lhsSeconds < rhsSeconds { return -1 }
    if lhsSeconds > rhsSeconds { return 1 }
    return 0
  }
}
