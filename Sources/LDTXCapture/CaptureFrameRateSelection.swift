// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

/// A frame rate range supported by a capture device's active format.
struct CaptureFrameRateRange: Equatable, Sendable {
  var minFrameRate: Double
  var maxFrameRate: Double
}

/// How a requested capture frame rate maps onto the active format's supported ranges.
///
/// Devices report nominal rates such as 60 fps with slightly different exact durations
/// (for example 1000000/60000240), and AVFoundation rejects a duration outside the range.
/// A request at a range boundary therefore uses the range's own boundary duration.
enum CaptureFrameRateSelection: Equatable, Sendable {
  /// The requested rate lies strictly inside a continuous range; use 1/requested.
  case requested(Int)
  /// Use the maximum rate (minimum frame duration) of the range at this index.
  case rangeMaximum(Int)
  /// Use the minimum rate (maximum frame duration) of the range at this index.
  case rangeMinimum(Int)
  /// The active format reports no usable frame rate ranges.
  case unavailable

  static let tolerance = 0.001

  static func select(
    requestedFrameRate: Int,
    supportedRanges: [CaptureFrameRateRange]
  ) -> Self {
    guard requestedFrameRate > 0 else { return .unavailable }
    let requested = Double(requestedFrameRate)
    let usableRanges = supportedRanges.enumerated().filter { _, range in
      range.minFrameRate > 0 && range.maxFrameRate >= range.minFrameRate
    }
    guard !usableRanges.isEmpty else { return .unavailable }

    for (index, range) in usableRanges
    where range.minFrameRate - tolerance <= requested
      && requested <= range.maxFrameRate + tolerance
    {
      if abs(requested - range.maxFrameRate) <= tolerance {
        return .rangeMaximum(index)
      }
      if abs(requested - range.minFrameRate) <= tolerance {
        return .rangeMinimum(index)
      }
      return .requested(requestedFrameRate)
    }

    var best: (selection: Self, distance: Double)?
    for (index, range) in usableRanges {
      let candidate: (selection: Self, distance: Double) =
        requested > range.maxFrameRate
        ? (.rangeMaximum(index), requested - range.maxFrameRate)
        : (.rangeMinimum(index), range.minFrameRate - requested)
      if best == nil || candidate.distance < best!.distance {
        best = candidate
      }
    }
    return best?.selection ?? .unavailable
  }
}
