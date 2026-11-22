// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@testable import LDTXCapture
import Testing

@Suite(.tags(.easy))
struct CaptureFrameDeliveryStatsUnitTestSuite {
  private static let frameNanoseconds: Int64 = 16_666_667

  private func drop(
    _ stats: inout CaptureFrameDeliveryStats,
    _ reason: CaptureFrameDropReason,
    at nanoseconds: UInt64
  ) -> CaptureFrameDeliveryReport? {
    stats.recordDropped(reason: reason, nowNanoseconds: nanoseconds)
  }

  @Test("Reports nothing before the window elapses")
  func reportsNothingBeforeWindowElapses() {
    var stats = CaptureFrameDeliveryStats(reportIntervalNanoseconds: 1_000_000_000)
    for index in 0..<10 {
      let pts = Int64(index) * Self.frameNanoseconds
      let report = stats.recordDelivered(
        presentationNanoseconds: pts,
        callbackStartNanoseconds: UInt64(pts),
        callbackEndNanoseconds: UInt64(pts)
      )
      #expect(report == nil)
    }
  }

  @Test("Summarizes intervals, long gaps, latency and handler time")
  func summarizesWindow() throws {
    var stats = CaptureFrameDeliveryStats(reportIntervalNanoseconds: 100_000_000)
    // Frames 0, 1, 2, then frame 3 is missing, then 4, 5, 6.
    let frameIndices: [Int64] = [0, 1, 2, 4, 5, 6]
    var report: CaptureFrameDeliveryReport?
    for (position, frameIndex) in frameIndices.enumerated() {
      let pts = frameIndex * Self.frameNanoseconds
      let isLast = position == frameIndices.count - 1
      let start = UInt64(pts) + (frameIndex == 4 ? 5_000_000 : 1_000_000)
      let end = isLast ? 200_000_000 : start + (frameIndex == 2 ? 3_000_000 : 500_000)
      report = stats.recordDelivered(
        presentationNanoseconds: pts,
        callbackStartNanoseconds: start,
        callbackEndNanoseconds: end
      )
      if !isLast { #expect(report == nil) }
    }
    let result = try #require(report)
    #expect(result.deliveredCount == 6)
    #expect(result.droppedCount == 0)
    #expect(result.intervalCount == 5)
    #expect(result.minIntervalNanoseconds == UInt64(Self.frameNanoseconds))
    #expect(result.maxIntervalNanoseconds == UInt64(2 * Self.frameNanoseconds))
    #expect(result.longIntervalCount == 1)
    #expect(result.maxDeliveryLatencyNanoseconds == 5_000_000)
    #expect(result.windowNanoseconds == 199_000_000)
  }

  @Test("Counts drops by reason and resets after reporting")
  func countsDropsAndResets() throws {
    var stats = CaptureFrameDeliveryStats(reportIntervalNanoseconds: 100)
    #expect(drop(&stats, .frameWasLate, at: 0) == nil)
    #expect(drop(&stats, .frameWasLate, at: 10) == nil)
    #expect(drop(&stats, .outOfBuffers, at: 20) == nil)
    #expect(drop(&stats, .discontinuity, at: 30) == nil)
    let firstReport = stats.recordDropped(reason: .other, nowNanoseconds: 100)
    let first = try #require(firstReport)
    #expect(first.droppedLateCount == 2)
    #expect(first.droppedOutOfBuffersCount == 1)
    #expect(first.droppedDiscontinuityCount == 1)
    #expect(first.droppedOtherCount == 1)
    #expect(first.droppedCount == 5)
    #expect(first.deliveredCount == 0)
    #expect(first.longIntervalCount == 0)

    let secondReport = stats.recordDropped(reason: .frameWasLate, nowNanoseconds: 200)
    let second = try #require(secondReport)
    #expect(second.droppedCount == 1)
    #expect(second.windowNanoseconds == 100)
  }

  @Test("Ignores missing and non-increasing presentation times")
  func ignoresInvalidPresentationTimes() throws {
    var stats = CaptureFrameDeliveryStats(reportIntervalNanoseconds: 100)
    _ = stats.recordDelivered(
      presentationNanoseconds: nil, callbackStartNanoseconds: 0, callbackEndNanoseconds: 0)
    _ = stats.recordDelivered(
      presentationNanoseconds: 50, callbackStartNanoseconds: 10, callbackEndNanoseconds: 10)
    let lastReport = stats.recordDelivered(
      presentationNanoseconds: 50, callbackStartNanoseconds: 20, callbackEndNanoseconds: 100)
    let report = try #require(lastReport)
    #expect(report.deliveredCount == 3)
    #expect(report.intervalCount == 0)
    #expect(report.meanIntervalNanoseconds == 0)
    #expect(report.maxDeliveryLatencyNanoseconds == 0)
    #expect(report.maxHandlerNanoseconds == 80)
  }
}
