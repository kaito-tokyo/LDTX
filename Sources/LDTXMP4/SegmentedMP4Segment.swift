// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum SegmentedMP4SegmentKind: Equatable, Sendable {
  case initialization
  case media(number: Int)
}

/// Content-independent measurements captured while a media segment is muxed.
/// These values are safe to expose to diagnostics because they describe only
/// timing and sample counts, never encoded media contents.
public struct SegmentedMP4SegmentDiagnostics: Equatable, Sendable {
  public var videoSampleCount: Int
  public var audioSampleCount: Int
  public var audioFrameCount: Int
  public var syncVideoSampleCount: Int
  public var maximumSyncVideoIntervalSeconds: Double?

  public init(
    videoSampleCount: Int = 0,
    audioSampleCount: Int = 0,
    audioFrameCount: Int = 0,
    syncVideoSampleCount: Int = 0,
    maximumSyncVideoIntervalSeconds: Double? = nil
  ) {
    self.videoSampleCount = videoSampleCount
    self.audioSampleCount = audioSampleCount
    self.audioFrameCount = audioFrameCount
    self.syncVideoSampleCount = syncVideoSampleCount
    self.maximumSyncVideoIntervalSeconds = maximumSyncVideoIntervalSeconds
  }
}

public struct SegmentedMP4Segment: Equatable, Sendable {
  public var kind: SegmentedMP4SegmentKind
  public var data: Data
  public var durationSeconds: Double?
  public var earliestPresentationTimeSeconds: Double?
  public var diagnostics: SegmentedMP4SegmentDiagnostics?

  public init(
    kind: SegmentedMP4SegmentKind,
    data: Data,
    durationSeconds: Double? = nil,
    earliestPresentationTimeSeconds: Double? = nil,
    diagnostics: SegmentedMP4SegmentDiagnostics? = nil
  ) {
    self.kind = kind
    self.data = data
    self.durationSeconds = durationSeconds
    self.earliestPresentationTimeSeconds = earliestPresentationTimeSeconds
    self.diagnostics = diagnostics
  }
}
