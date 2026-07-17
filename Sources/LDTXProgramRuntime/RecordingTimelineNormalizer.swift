// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation

final class RecordingTimelineNormalizer: @unchecked Sendable {
  typealias Output = @Sendable (CMSampleBuffer) -> Void

  private let origin: CMTime

  init(origin: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
    self.origin = origin
  }

  func submit(_ sampleBuffer: CMSampleBuffer, trackID: String, output: @escaping Output) {
    guard let normalized = Self.retimed(sampleBuffer, subtracting: origin) else { return }
    output(normalized)
  }

  func finish() {}

  private static func retimed(
    _ sampleBuffer: CMSampleBuffer,
    subtracting origin: CMTime
  ) -> CMSampleBuffer? {
    var count = 0
    guard
      CMSampleBufferGetSampleTimingInfoArray(
        sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
      count > 0
    else { return nil }
    var timing = Array(repeating: CMSampleTimingInfo(), count: count)
    guard
      CMSampleBufferGetSampleTimingInfoArray(
        sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count) == noErr
    else { return nil }
    for index in timing.indices {
      if timing[index].presentationTimeStamp.isValid {
        timing[index].presentationTimeStamp = CMTimeSubtract(
          timing[index].presentationTimeStamp, origin)
      }
      if timing[index].decodeTimeStamp.isValid {
        timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, origin)
      }
    }
    var output: CMSampleBuffer?
    guard
      CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault,
        sampleBuffer: sampleBuffer,
        sampleTimingEntryCount: timing.count,
        sampleTimingArray: &timing,
        sampleBufferOut: &output
      ) == noErr
    else { return nil }
    return output
  }
}
