// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXOutputMedia

final class RecordingTimelineNormalizer: @unchecked Sendable {
  typealias Output = @Sendable (CMSampleBuffer) -> Void

  private let lock = NSLock()
  private var origin: CMTime?
  private var isFinished = false

  init(origin: CMTime? = nil) {
    self.origin = origin
  }

  @discardableResult
  func activate(at origin: CMTime) -> CMTime? {
    guard origin.isNumeric else { return nil }
    return lock.withLock {
      guard !isFinished else { return nil }
      if self.origin == nil { self.origin = origin }
      return self.origin
    }
  }

  func submit(_ sampleBuffer: CMSampleBuffer, trackID: String, output: @escaping Output) {
    guard let origin = lock.withLock({ isFinished ? nil : origin }) else { return }
    guard let normalized = Self.retimed(sampleBuffer, subtracting: origin) else { return }
    output(normalized)
  }

  /// Retimes a compressed Program-audio packet for recording without changing
  /// the packet shared with other output consumers (for example YouTube).
  func normalized(_ packet: ProgramOutputAACPacket) -> ProgramOutputAACPacket? {
    guard let origin = lock.withLock({ isFinished ? nil : origin }) else { return nil }
    var result = packet
    let presentationTime = CMTime(
      value: CMTimeValue(packet.accessUnit.presentationTime.value),
      timescale: CMTimeScale(packet.accessUnit.presentationTime.timescale))
    let normalized = CMTimeSubtract(presentationTime, origin)
    guard normalized.isNumeric else { return nil }
    result.accessUnit.presentationTime = ProgramOutputMediaTime(
      value: normalized.value,
      timescale: normalized.timescale)
    return result
  }

  func finish() {
    lock.withLock { isFinished = true }
  }

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
