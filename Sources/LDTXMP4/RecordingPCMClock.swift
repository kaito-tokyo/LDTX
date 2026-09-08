// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation

/// Separates the converter's sample-count clock from the recording source clock.
/// Access is confined to the writer queue.
final class RecordingPCMClock {
  let sampleRate: CMTimeScale
  private var origin: CMTime?
  private var frames: Int64 = 0
  private var anchors: [(frame: Int64, time: CMTime)] = []
  private var lastMappedAnchor = 0
  var retainedAnchorCount: Int { anchors.count }

  init(sampleRate: CMTimeScale) { self.sampleRate = sampleRate }

  func converterSample(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
    let count = CMSampleBufferGetNumSamples(sample)
    let (nextFrames, overflow) = frames.addingReportingOverflow(Int64(count))
    guard sample.presentationTimeStamp.isNumeric, sampleRate > 0, count > 0, !overflow else {
      throw AACAudioEncoderError.invalidSample
    }
    if origin == nil {
      // Keep the converter origin at or before the source origin. The muxer
      // can clip AAC priming to time zero; rounding upward would map that
      // clipped boundary to a negative recording timestamp. Source anchors
      // retain the original fractional time regardless of this internal grid.
      origin = CMTimeConvertScale(
        sample.presentationTimeStamp, timescale: sampleRate, method: .roundTowardNegativeInfinity)
    }
    guard let origin else { throw AACAudioEncoderError.invalidSample }
    anchors.append((frames, sample.presentationTimeStamp))
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: sampleRate),
      presentationTimeStamp: CMTimeAdd(origin, CMTime(value: frames, timescale: sampleRate)),
      decodeTimeStamp: .invalid)
    var result: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1,
      sampleTimingArray: &timing, sampleBufferOut: &result)
    guard status == noErr, let result else {
      throw AACAudioEncoderError.sampleCreationFailed(status)
    }
    frames = nextFrames
    return result
  }

  func sourceTime(for nominal: CMTime, consuming: Bool = true) throws -> CMTime {
    guard nominal.isNumeric, let origin, !anchors.isEmpty else {
      throw AACAudioEncoderError.invalidSample
    }
    let frame = CMTimeConvertScale(
      CMTimeSubtract(nominal, origin), timescale: sampleRate,
      method: .roundHalfAwayFromZero
    ).value
    guard anchors[0].frame == 0 || frame >= anchors[0].frame else {
      throw AACAudioEncoderError.invalidSample
    }
    // Binary search avoids scanning the complete recording for each packet.
    var lower = 0
    var upper = anchors.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if anchors[middle].frame <= frame { lower = middle + 1 } else { upper = middle }
    }
    let index = max(0, lower - 1)
    if consuming { lastMappedAnchor = max(lastMappedAnchor, index) }
    let anchor = anchors[index]
    return CMTimeAdd(anchor.time, CMTime(value: frame - anchor.frame, timescale: sampleRate))
  }

  /// Call only after a complete fragment was rewritten successfully. Retain
  /// the final anchor for the next fragment's boundary and trailing padding.
  func discardEmittedHistory() {
    if lastMappedAnchor > 0 { anchors.removeFirst(lastMappedAnchor) }
    lastMappedAnchor = 0
  }
}
