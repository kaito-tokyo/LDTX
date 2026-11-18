// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
@testable import LDTXProgramRuntime
import Testing

extension OutputTestSuite {
  @Suite
  struct ProgramVideoPTSSelectorGridUnitTestSuite {
    private static let frameDuration = CMTime(value: 1, timescale: 60)
    private static let nanosecondsPerFrame = 1_000_000_000.0 / 60

    private static func sourcePTS(frame: Int, offsetMilliseconds: Double) -> CMTime {
      let nanoseconds =
        5_000_000_000 + Double(frame) * nanosecondsPerFrame + offsetMilliseconds * 1_000_000
      return CMTime(value: CMTimeValue(nanoseconds.rounded()), timescale: 1_000_000_000)
    }

    private static func advancedPTS(
      _ selector: inout ProgramVideoPTSSelector,
      _ sourcePTS: CMTime
    ) -> CMTime? {
      guard
        case .advanced(let pts) = selector.select(
          masterCameraID: "master-camera",
          masterPresentationTime: sourcePTS,
          frameDuration: frameDuration
        )
      else { return nil }
      return pts
    }

    @Test("Jittered master PTS are snapped to a constant frame interval")
    func jitteredMasterPTSAreSnappedToAConstantFrameInterval() {
      // The phase pattern recorded from a capture device that re-anchors its
      // timestamps every 40 ms while delivering 60 frames per second.
      let offsets: [Double] = [0, 0, 0, -10, -10, -3.3, -3.3, 3.3, 3.3, 3.3, -6.7, -6.7]
      var selector = ProgramVideoPTSSelector()
      var outputs: [CMTime] = []
      for frame in 0..<120 {
        let source = Self.sourcePTS(frame: frame, offsetMilliseconds: offsets[frame % 12])
        guard let output = Self.advancedPTS(&selector, source) else {
          Issue.record("Frame \(frame) must advance")
          return
        }
        let error = abs(CMTimeSubtract(output, source).seconds)
        #expect(error <= Self.frameDuration.seconds)
        outputs.append(output)
      }
      // A nanosecond-timescale origin cannot hold 1/60 s exactly, so each
      // interval may round by one nanosecond.
      for (previous, next) in zip(outputs, outputs.dropFirst()) {
        let interval = CMTimeSubtract(next, previous).seconds
        #expect(abs(interval - Self.frameDuration.seconds) < 0.000_001)
      }
    }

    @Test("Slower master leaves grid gaps without drifting")
    func slowerMasterLeavesGridGapsWithoutDrifting() {
      var selector = ProgramVideoPTSSelector()
      let origin = CMTime(value: 1_000_000_000, timescale: 1_000_000_000)
      let sourceInterval = 1_001_000_000.0 / 60_000
      for frame in 0..<6_000 {
        let source = CMTimeAdd(
          origin,
          CMTime(
            value: CMTimeValue((Double(frame) * sourceInterval * 1e9).rounded()),
            timescale: 1_000_000_000)
        )
        guard let output = Self.advancedPTS(&selector, source) else {
          Issue.record("Frame \(frame) must advance")
          return
        }
        #expect(abs(CMTimeSubtract(output, source).seconds) <= Self.frameDuration.seconds / 2)
      }
    }

    @Test("Faster master drops frames instead of running ahead")
    func fasterMasterDropsFramesInsteadOfRunningAhead() {
      var selector = ProgramVideoPTSSelector()
      var advancedCount = 0
      for frame in 0..<240 {
        let source = CMTime(value: CMTimeValue(1_000 + frame), timescale: 120)
        switch selector.select(
          masterCameraID: "master-camera",
          masterPresentationTime: source,
          frameDuration: Self.frameDuration
        ) {
        case .advanced(let output):
          advancedCount += 1
          #expect(CMTimeSubtract(output, source).seconds <= Self.frameDuration.seconds)
        case .stalled:
          break
        default:
          Issue.record("Frame \(frame) must advance or stall")
        }
      }
      #expect((119...121).contains(advancedCount))
    }

    @Test("Frame rate change re-anchors the grid")
    func frameRateChangeReanchorsTheGrid() {
      var selector = ProgramVideoPTSSelector()
      #expect(
        selector.select(
          masterCameraID: "master-camera",
          masterPresentationTime: CMTime(value: 600, timescale: 600),
          frameDuration: Self.frameDuration
        ) == .advanced(CMTime(value: 600, timescale: 600)))
      let reanchoredPTS = CMTime(value: 623, timescale: 600)
      #expect(
        selector.select(
          masterCameraID: "master-camera",
          masterPresentationTime: reanchoredPTS,
          frameDuration: CMTime(value: 1, timescale: 30)
        ) == .advanced(reanchoredPTS))
    }
  }
}
