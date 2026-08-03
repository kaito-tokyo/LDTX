// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXYouTubeOutputProtocol

struct YouTubeOutputMediaBacklog: Sendable {
  enum DropReason: String, Equatable, Sendable {
    case videoLimit
    case audioLimit
    case audioAlignment
  }

  struct DropReport: Equatable, Sendable {
    var reason: DropReason
    var videoUnitCount: Int
    var audioBufferCount: Int
    var recoveredAtKeyFrame: Bool
  }

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
  private var pendingDropReport: DropReport?
  private var pendingAudioLimitDropCount = 0
  private var pendingAudioAlignmentDropCount = 0

  init(maximumVideoCount: Int = 120, maximumAudioCount: Int = 256) {
    self.maximumVideoCount = maximumVideoCount
    self.maximumAudioCount = maximumAudioCount
  }

  var count: Int { video.count + audio.count }
  var isEmpty: Bool { video.isEmpty && audio.isEmpty }

  @discardableResult
  mutating func appendVideo(
    _ accessUnit: YouTubeOutputH264AccessUnit,
    format: YouTubeOutputH264Format?
  ) -> DropReport? {
    if let format { videoFormat = format }
    if requiresKeyFrame {
      guard accessUnit.isKeyFrame else {
        pendingDropReport?.videoUnitCount += 1
        return nil
      }
      requiresKeyFrame = false
      minimumAudioTime = accessUnit.presentationTime
      video = [accessUnit]
      var report = pendingDropReport
      report?.recoveredAtKeyFrame = true
      pendingDropReport = nil
      return report
    }
    video.append(accessUnit)
    if video.count > maximumVideoCount {
      let retainedVideoCount = accessUnit.isKeyFrame ? 1 : 0
      let report = DropReport(
        reason: .videoLimit,
        videoUnitCount: video.count - retainedVideoCount,
        audioBufferCount: audio.count,
        recoveredAtKeyFrame: accessUnit.isKeyFrame)
      video.removeAll(keepingCapacity: true)
      audio.removeAll(keepingCapacity: true)
      if accessUnit.isKeyFrame {
        minimumAudioTime = accessUnit.presentationTime
        video.append(accessUnit)
        return report
      } else {
        requiresKeyFrame = true
        minimumAudioTime = nil
        pendingDropReport = report
      }
    }
    return nil
  }

  mutating func appendAudio(_ buffer: YouTubeOutputPCMBuffer) {
    guard !requiresKeyFrame else {
      pendingDropReport?.audioBufferCount += 1
      return
    }
    if let minimumAudioTime, Self.compare(buffer.presentationTime, minimumAudioTime) < 0 {
      pendingAudioAlignmentDropCount += 1
      return
    }
    audio.append(buffer)
    if audio.count > maximumAudioCount {
      let removedCount = audio.count - maximumAudioCount
      audio.removeFirst(removedCount)
      pendingAudioLimitDropCount += removedCount
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

  mutating func takeCompletedDropReports() -> [DropReport] {
    var reports: [DropReport] = []
    if pendingAudioLimitDropCount > 0 {
      reports.append(DropReport(
        reason: .audioLimit,
        videoUnitCount: 0,
        audioBufferCount: pendingAudioLimitDropCount,
        recoveredAtKeyFrame: false))
    }
    if pendingAudioAlignmentDropCount > 0 {
      reports.append(DropReport(
        reason: .audioAlignment,
        videoUnitCount: 0,
        audioBufferCount: pendingAudioAlignmentDropCount,
        recoveredAtKeyFrame: true))
    }
    pendingAudioLimitDropCount = 0
    pendingAudioAlignmentDropCount = 0
    return reports
  }

  mutating func takePendingDropReports() -> [DropReport] {
    var reports = takeCompletedDropReports()
    if let pendingDropReport { reports.append(pendingDropReport) }
    pendingDropReport = nil
    return reports
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
