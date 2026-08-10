// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation

/// Maps all tracks in one output session onto a shared, small-valued timeline.
///
/// The default one-second offset keeps decoded timestamps close to zero without
/// requiring the first decode timestamp to be exactly zero.
public struct YouTubeOutputMediaTimeline: Sendable {
  public let outputOffset: YouTubeOutputMediaTime
  public private(set) var origin: YouTubeOutputMediaTime?

  public init(
    outputOffset: YouTubeOutputMediaTime = YouTubeOutputMediaTime(value: 1, timescale: 1)
  ) {
    self.outputOffset = outputOffset
  }

  @discardableResult
  public mutating func establishOrigin(at time: YouTubeOutputMediaTime) -> Bool {
    guard origin == nil, Self.isNumeric(time), Self.isNumeric(outputOffset) else { return false }
    origin = time
    return true
  }

  /// Returns whether a complete media unit starts at or after the session origin.
  ///
  /// Live output deliberately discards a unit that starts before the origin,
  /// even when part of that unit would extend beyond the origin.
  public func startsAtOrAfterOrigin(_ time: YouTubeOutputMediaTime) -> Bool {
    guard let origin, Self.isNumeric(time) else { return false }
    return CMTimeCompare(time.cmTime, origin.cmTime) >= 0
  }

  public func translate(_ time: YouTubeOutputMediaTime) -> YouTubeOutputMediaTime? {
    guard let origin, Self.isNumeric(time), Self.isNumeric(outputOffset) else { return nil }
    let translated = CMTimeAdd(CMTimeSubtract(time.cmTime, origin.cmTime), outputOffset.cmTime)
    guard translated.isNumeric else { return nil }
    let converted = CMTimeConvertScale(translated, timescale: time.timescale, method: .default)
    guard converted.isNumeric else { return nil }
    return YouTubeOutputMediaTime(value: converted.value, timescale: converted.timescale)
  }

  private static func isNumeric(_ time: YouTubeOutputMediaTime) -> Bool {
    time.timescale > 0 && time.cmTime.isNumeric
  }
}

/// Delays one encoded frame so its display duration can cover an upstream gap.
public struct YouTubeOutputVideoFrameHold: Sendable {
  private var pending: YouTubeOutputH264AccessUnit?
  private var nominalDurationSeconds: Double?

  public init() {}

  public mutating func append(
    _ accessUnit: YouTubeOutputH264AccessUnit
  ) -> YouTubeOutputH264AccessUnit? {
    defer { pending = accessUnit }
    guard var previous = pending else { return nil }
    if let duration = Self.duration(
      from: previous.presentationTime,
      to: accessUnit.presentationTime
    ) {
      previous.duration = duration
      let seconds = Double(duration.value) / Double(duration.timescale)
      nominalDurationSeconds = min(nominalDurationSeconds ?? seconds, seconds)
    }
    return previous
  }

  public mutating func finish(defaultFrameRate: Int32 = 30) -> YouTubeOutputH264AccessUnit? {
    guard var final = pending else { return nil }
    pending = nil
    if final.duration.value <= 0 || final.duration.timescale <= 0 {
      if let nominalDurationSeconds {
        let timescale = max(final.presentationTime.timescale, 1)
        final.duration = YouTubeOutputMediaTime(
          value: max(Int64((nominalDurationSeconds * Double(timescale)).rounded()), 1),
          timescale: timescale
        )
      } else {
        final.duration = YouTubeOutputMediaTime(value: 1, timescale: max(defaultFrameRate, 1))
      }
    }
    return final
  }

  private static func duration(
    from start: YouTubeOutputMediaTime,
    to end: YouTubeOutputMediaTime
  ) -> YouTubeOutputMediaTime? {
    guard start.timescale > 0, end.timescale > 0 else { return nil }
    let seconds =
      Double(end.value) / Double(end.timescale)
      - Double(start.value) / Double(start.timescale)
    guard seconds > 0, seconds.isFinite else { return nil }
    let timescale = start.timescale
    let value = Int64((seconds * Double(timescale)).rounded())
    guard value > 0 else { return nil }
    return YouTubeOutputMediaTime(value: value, timescale: timescale)
  }
}

extension YouTubeOutputMediaTime {
  fileprivate var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
}
