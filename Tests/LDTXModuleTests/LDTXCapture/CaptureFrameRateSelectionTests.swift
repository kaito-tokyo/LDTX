// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@testable import LDTXCapture
import Testing

@Suite(.tags(.easy))
struct CaptureFrameRateSelectionUnitTestSuite {
  private static func fixed(_ rates: Double...) -> [CaptureFrameRateRange] {
    rates.map { CaptureFrameRateRange(minFrameRate: $0, maxFrameRate: $0) }
  }

  @Test("Uses the device's own boundary duration for a fixed rate")
  func usesBoundaryForFixedRate() {
    // Elgato Game Capture Neo reports "60.00" as 1000000/60000240; exactly 1/60 is rejected.
    #expect(
      CaptureFrameRateSelection.select(
        requestedFrameRate: 60,
        supportedRanges: Self.fixed(60.00024, 50, 30.00003, 25)
      ) == .rangeMaximum(0))
    #expect(
      CaptureFrameRateSelection.select(
        requestedFrameRate: 30,
        supportedRanges: Self.fixed(60.00024, 50, 30.00003, 25)
      ) == .rangeMaximum(2))
    #expect(
      CaptureFrameRateSelection.select(
        requestedFrameRate: 5,
        supportedRanges: [CaptureFrameRateRange(minFrameRate: 5, maxFrameRate: 60)]
      ) == .rangeMinimum(0))
  }

  @Test("Selects the requested rate inside a continuous range")
  func selectsSupportedRate() {
    #expect(
      CaptureFrameRateSelection.select(
        requestedFrameRate: 30,
        supportedRanges: [CaptureFrameRateRange(minFrameRate: 5, maxFrameRate: 60)]
      ) == .requested(30))
  }

  @Test("Falls back to the closest maximum below an unsupported request")
  func fallsBackToClosestMaximum() {
    #expect(
      CaptureFrameRateSelection.select(
        requestedFrameRate: 60,
        supportedRanges: Self.fixed(30, 24, 20, 15)
      ) == .rangeMaximum(0))
    #expect(
      CaptureFrameRateSelection.select(
        requestedFrameRate: 60,
        supportedRanges: Self.fixed(30, 59.94)
      ) == .rangeMaximum(1))
  }

  @Test("Falls back to the closest minimum above an unsupported request")
  func fallsBackToClosestMinimum() {
    #expect(
      CaptureFrameRateSelection.select(
        requestedFrameRate: 10,
        supportedRanges: Self.fixed(60, 25)
      ) == .rangeMinimum(1))
  }

  @Test("Reports unavailable for unusable ranges or requests")
  func reportsUnavailable() {
    #expect(
      CaptureFrameRateSelection.select(requestedFrameRate: 60, supportedRanges: [])
        == .unavailable)
    #expect(
      CaptureFrameRateSelection.select(
        requestedFrameRate: 60,
        supportedRanges: [CaptureFrameRateRange(minFrameRate: 0, maxFrameRate: 0)]
      ) == .unavailable)
    #expect(
      CaptureFrameRateSelection.select(
        requestedFrameRate: 0,
        supportedRanges: Self.fixed(60)
      ) == .unavailable)
  }
}
