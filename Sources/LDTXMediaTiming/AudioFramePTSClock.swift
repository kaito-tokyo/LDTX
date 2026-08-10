// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation

public final class AudioFramePTSClock: @unchecked Sendable {
  public let sampleRate: Int

  private var nextFrameIndex: Int64?

  public init(sampleRate: Int = 48_000) throws {
    guard sampleRate > 0 else {
      throw AudioChannelTimelineError.invalidConfiguration
    }
    self.sampleRate = sampleRate
  }

  public func nextPresentationTime(
    anchorPresentationTime: CMTime,
    frameCount: Int
  ) throws -> CMTime {
    guard frameCount > 0 else {
      throw AudioChannelTimelineError.invalidSampleBuffer
    }

    let frameIndex: Int64
    if let nextFrameIndex {
      frameIndex = nextFrameIndex
    } else {
      frameIndex = try AudioChannelTimeline.frameIndex(
        for: anchorPresentationTime,
        sampleRate: sampleRate
      )
    }

    nextFrameIndex = frameIndex + Int64(frameCount)
    return AudioChannelTimeline.presentationTime(
      forFrameIndex: frameIndex,
      sampleRate: sampleRate
    )
  }
}
