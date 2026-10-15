// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation

struct SegmentedMP4TrackTiming: Equatable, Sendable {
  var trackID: Int32
  var start: CMTime
  var duration: CMTime
}

public enum SegmentedMP4SegmentKind: Equatable, Sendable {
  case initialization
  case media(number: Int)
}

public struct SegmentedMP4Segment: Equatable, Sendable {
  var trackTimings: [SegmentedMP4TrackTiming] = []
  public var kind: SegmentedMP4SegmentKind
  public var data: Data
  public var durationSeconds: Double?
  public var earliestPresentationTimeSeconds: Double?

  public init(
    kind: SegmentedMP4SegmentKind,
    data: Data,
    durationSeconds: Double? = nil,
    earliestPresentationTimeSeconds: Double? = nil
  ) {
    self.kind = kind
    self.data = data
    self.durationSeconds = durationSeconds
    self.earliestPresentationTimeSeconds = earliestPresentationTimeSeconds
  }
}
