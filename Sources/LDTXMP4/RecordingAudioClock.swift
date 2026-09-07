// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia

/// Recording-only audio timing. The owning pipeline serializes all calls.
public final class RecordingAudioClock {
  private let pcm: RecordingPCMClock
  private var trackID: UInt32?

  public init(formatDescription: CMAudioFormatDescription) throws {
    guard let format = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
      format.pointee.mSampleRate > 0, format.pointee.mSampleRate <= Double(Int32.max)
    else { throw AACAudioEncoderError.invalidFormat }
    pcm = RecordingPCMClock(sampleRate: CMTimeScale(format.pointee.mSampleRate))
  }

  public func converterSample(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
    try pcm.converterSample(sample)
  }

  public func retime(_ segment: SegmentedMP4Segment) throws -> SegmentedMP4Segment {
    var result = segment
    if case .initialization = segment.kind {
      trackID = try RecordingAudioFragmentClock.audioTrackID(in: segment.data)
    }
    guard let trackID else { throw MP4TimingBoxError.malformed() }
    let clock = RecordingAudioFragmentClock(
      sourceTimescale: pcm.sampleRate, destinationTimescale: 1_000_000_000,
      map: { [pcm] in try pcm.sourceTime(for: $0) }, trackID: trackID)
    switch segment.kind {
    case .initialization: result.data = try clock.initialization(segment.data)
    case .media:
      result.data = try clock.fragment(segment.data)
      for index in result.trackTimings.indices {
        let timing = result.trackTimings[index]
        guard timing.trackID == Int32(bitPattern: trackID), timing.start.isNumeric,
          timing.duration.isNumeric, timing.duration > .zero
        else { continue }
        let start = try pcm.sourceTime(for: timing.start, consuming: false)
        let end = try pcm.sourceTime(
          for: CMTimeAdd(timing.start, timing.duration), consuming: false)
        result.trackTimings[index].start = start
        result.trackTimings[index].duration = CMTimeSubtract(end, start)
      }
      let valid = result.trackTimings.filter {
        $0.start.isNumeric && $0.duration.isNumeric && $0.duration > .zero
      }
      if let start = valid.map(\.start).min(),
        let duration = valid.map(\.duration).max()
      {
        result.earliestPresentationTimeSeconds = start.seconds
        result.durationSeconds = duration.seconds
      }
      pcm.discardEmittedHistory()
    }
    return result
  }
}
