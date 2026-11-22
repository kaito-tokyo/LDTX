// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

/// Why AVFoundation dropped a captured video frame before delivering it.
enum CaptureFrameDropReason: Equatable, Sendable {
  case frameWasLate
  case outOfBuffers
  case discontinuity
  case other
}

/// Frame delivery statistics for one capture output over one reporting window.
struct CaptureFrameDeliveryReport: Equatable, Sendable {
  var windowNanoseconds: UInt64
  var deliveredCount: Int
  var droppedLateCount: Int
  var droppedOutOfBuffersCount: Int
  var droppedDiscontinuityCount: Int
  var droppedOtherCount: Int
  /// Presentation-time intervals between consecutive delivered frames.
  var intervalCount: Int
  var meanIntervalNanoseconds: UInt64
  var minIntervalNanoseconds: UInt64
  var maxIntervalNanoseconds: UInt64
  /// Intervals longer than 1.5 times the window's mean interval.
  var longIntervalCount: Int
  /// Largest delay from a frame's presentation time to its delivery callback.
  var maxDeliveryLatencyNanoseconds: UInt64
  /// Longest time the sample handler held the shared delivery queue.
  var maxHandlerNanoseconds: UInt64

  var droppedCount: Int {
    droppedLateCount + droppedOutOfBuffersCount + droppedDiscontinuityCount + droppedOtherCount
  }
}

/// Accumulates per-output capture delivery timing and emits a report once per window.
///
/// All timestamps are nanoseconds on the host time clock, which is also the clock of
/// presentation timestamps produced by capture devices.
struct CaptureFrameDeliveryStats {
  static let defaultReportIntervalNanoseconds: UInt64 = 10_000_000_000
  private static let longIntervalNumerator: UInt64 = 3
  private static let longIntervalDenominator: UInt64 = 2

  private let reportIntervalNanoseconds: UInt64
  private var windowStartNanoseconds: UInt64?
  private var lastPresentationNanoseconds: Int64?
  private var intervals: [UInt64] = []
  private var deliveredCount = 0
  private var droppedLateCount = 0
  private var droppedOutOfBuffersCount = 0
  private var droppedDiscontinuityCount = 0
  private var droppedOtherCount = 0
  private var maxDeliveryLatencyNanoseconds: UInt64 = 0
  private var maxHandlerNanoseconds: UInt64 = 0

  init(reportIntervalNanoseconds: UInt64 = Self.defaultReportIntervalNanoseconds) {
    self.reportIntervalNanoseconds = max(reportIntervalNanoseconds, 1)
    intervals.reserveCapacity(1_024)
  }

  mutating func recordDelivered(
    presentationNanoseconds: Int64?,
    callbackStartNanoseconds: UInt64,
    callbackEndNanoseconds: UInt64
  ) -> CaptureFrameDeliveryReport? {
    beginWindowIfNeeded(at: callbackStartNanoseconds)
    deliveredCount += 1
    if let presentationNanoseconds {
      if let lastPresentationNanoseconds, presentationNanoseconds > lastPresentationNanoseconds {
        intervals.append(UInt64(presentationNanoseconds - lastPresentationNanoseconds))
      }
      lastPresentationNanoseconds = presentationNanoseconds
      if presentationNanoseconds >= 0, callbackStartNanoseconds > UInt64(presentationNanoseconds) {
        maxDeliveryLatencyNanoseconds = max(
          maxDeliveryLatencyNanoseconds,
          callbackStartNanoseconds - UInt64(presentationNanoseconds)
        )
      }
    }
    if callbackEndNanoseconds > callbackStartNanoseconds {
      maxHandlerNanoseconds = max(
        maxHandlerNanoseconds, callbackEndNanoseconds - callbackStartNanoseconds)
    }
    return reportIfDue(at: callbackEndNanoseconds)
  }

  mutating func recordDropped(
    reason: CaptureFrameDropReason,
    nowNanoseconds: UInt64
  ) -> CaptureFrameDeliveryReport? {
    beginWindowIfNeeded(at: nowNanoseconds)
    switch reason {
    case .frameWasLate: droppedLateCount += 1
    case .outOfBuffers: droppedOutOfBuffersCount += 1
    case .discontinuity: droppedDiscontinuityCount += 1
    case .other: droppedOtherCount += 1
    }
    return reportIfDue(at: nowNanoseconds)
  }

  private mutating func beginWindowIfNeeded(at nanoseconds: UInt64) {
    if windowStartNanoseconds == nil {
      windowStartNanoseconds = nanoseconds
    }
  }

  private mutating func reportIfDue(at nanoseconds: UInt64) -> CaptureFrameDeliveryReport? {
    guard let windowStartNanoseconds, nanoseconds >= windowStartNanoseconds,
      nanoseconds - windowStartNanoseconds >= reportIntervalNanoseconds
    else {
      return nil
    }
    let report = makeReport(windowNanoseconds: nanoseconds - windowStartNanoseconds)
    resetWindow(startingAt: nanoseconds)
    return report
  }

  private func makeReport(windowNanoseconds: UInt64) -> CaptureFrameDeliveryReport {
    let total = intervals.reduce(UInt64(0), &+)
    let mean = intervals.isEmpty ? 0 : total / UInt64(intervals.count)
    let longThreshold = mean * Self.longIntervalNumerator / Self.longIntervalDenominator
    return CaptureFrameDeliveryReport(
      windowNanoseconds: windowNanoseconds,
      deliveredCount: deliveredCount,
      droppedLateCount: droppedLateCount,
      droppedOutOfBuffersCount: droppedOutOfBuffersCount,
      droppedDiscontinuityCount: droppedDiscontinuityCount,
      droppedOtherCount: droppedOtherCount,
      intervalCount: intervals.count,
      meanIntervalNanoseconds: mean,
      minIntervalNanoseconds: intervals.min() ?? 0,
      maxIntervalNanoseconds: intervals.max() ?? 0,
      longIntervalCount: mean == 0 ? 0 : intervals.count(where: { $0 > longThreshold }),
      maxDeliveryLatencyNanoseconds: maxDeliveryLatencyNanoseconds,
      maxHandlerNanoseconds: maxHandlerNanoseconds
    )
  }

  private mutating func resetWindow(startingAt nanoseconds: UInt64) {
    windowStartNanoseconds = nanoseconds
    intervals.removeAll(keepingCapacity: true)
    deliveredCount = 0
    droppedLateCount = 0
    droppedOutOfBuffersCount = 0
    droppedDiscontinuityCount = 0
    droppedOtherCount = 0
    maxDeliveryLatencyNanoseconds = 0
    maxHandlerNanoseconds = 0
  }
}
