// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXYouTubeOutputProtocol

struct YouTubeOutputRecoveryPolicy: Sendable {
  struct Retry: Equatable, Sendable {
    var attempt: Int
    var revision: UInt64
    var delay: TimeInterval
  }

  private(set) var attempt = 0
  private(set) var revision: UInt64 = 0
  let maximumAttempts: Int
  let retryDelay: TimeInterval

  init(maximumAttempts: Int = 3, retryDelay: TimeInterval = 4) {
    self.maximumAttempts = maximumAttempts
    self.retryDelay = retryDelay
  }

  mutating func nextRetry() -> Retry? {
    attempt += 1
    guard attempt <= maximumAttempts else { return nil }
    revision += 1
    return Retry(attempt: attempt, revision: revision, delay: retryDelay)
  }

  mutating func noteStableConnection() {
    attempt = 0
  }
}

struct YouTubeOutputCheckpointUpdate: Equatable, Sendable {
  var nextMediaSegmentNumber: Int?
  var initializationSegment: Data?
  var availabilityStartTime: Date? = nil
  var nextMediaTimeSeconds: Double? = nil

  static func validated(
    resetRequest: YouTubeOutputResetRequest,
    expectedContext: YouTubeOutputContext,
    configurationFingerprint: String
  ) throws -> Self? {
    guard resetRequest.context == expectedContext else { return nil }
    guard
      resetRequest.configurationFingerprint == nil
        || resetRequest.configurationFingerprint == configurationFingerprint
    else {
      throw YouTubeOutputCheckpointError.configurationMismatch
    }
    return Self(
      nextMediaSegmentNumber: resetRequest.nextMediaSegmentNumber,
      initializationSegment: resetRequest.initializationSegment,
      availabilityStartTime: resetRequest.availabilityStartTime,
      nextMediaTimeSeconds: resetRequest.nextMediaTimeSeconds)
  }
}

enum YouTubeOutputCheckpointError: Error, Equatable {
  case configurationMismatch
}

struct YouTubeOutputResumeGate: Sendable {
  private(set) var requiresKeyFrame = true

  mutating func reset() {
    requiresKeyFrame = true
  }

  mutating func filter(_ batch: YouTubeOutputMediaBatch) -> YouTubeOutputMediaBatch? {
    guard requiresKeyFrame else { return batch }
    guard let keyFrameIndex = batch.video.firstIndex(where: \.isKeyFrame) else { return nil }
    let keyFrameTime = batch.video[keyFrameIndex].presentationTime
    var result = batch
    result.video = Array(batch.video[keyFrameIndex...])
    result.audio = batch.audio.filter {
      Self.compare($0.presentationTime, keyFrameTime) >= 0
    }
    requiresKeyFrame = false
    return result
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
