// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation

struct InputDeviceSegmentedMP4TrackTiming: Equatable, Sendable {
  var trackID: Int32
  var start: CMTime
  var duration: CMTime
}

public enum InputDeviceSegmentedMP4SegmentKind: Equatable, Sendable {
  case initialization
  case media(number: Int)
}

public struct InputDeviceSegmentedMP4Segment: Equatable, Sendable {
  var trackTimings: [InputDeviceSegmentedMP4TrackTiming] = []
  public var kind: InputDeviceSegmentedMP4SegmentKind
  public var data: Data
  public var durationSeconds: Double?
  public var earliestPresentationTimeSeconds: Double?

  public init(
    kind: InputDeviceSegmentedMP4SegmentKind,
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

