// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

@testable import LDTXWorkspaceAppletController
import Testing

@Suite struct StreamDeckReportsUnitTestSuite {
  private func report(_ keys: [Int] = []) -> [UInt8] {
    var bytes: [UInt8] = [1, 0, 15, 0] + Array(repeating: 0, count: 15)
    for key in keys { bytes[4 + key] = 1 }
    return bytes
  }

  @Test func heldKeysRepeatedReportsAndMalformedReports() {
    var state = StreamDeckPressState()
    state.seed(report([1]))
    #expect(state.receive(report([1])).isEmpty)
    #expect(state.receive(report([1])).isEmpty)
    #expect(state.receive(report()).isEmpty)
    #expect(state.receive(report([1])).isEmpty)
    #expect(state.receive([1, 0]).isEmpty)
    #expect(state.receive([2, 0] + Array(repeating: 0, count: 17)).isEmpty)
    #expect(state.receive(report([1])).isEmpty)
    #expect(state.receive(report([0, 1, 2, 14])) == [0, 2])
    #expect(state.receive(report()) == [1])
    #expect(state.receive(report()).isEmpty)
    state = StreamDeckPressState()
    state.seed(report([0]))
    #expect(state.receive(report([0])).isEmpty)
  }

  @Test func imageChunkBoundariesAndPadding() {
    for size in [1, 1016, 1017, 2032, 2033] {
      let image = (0..<size).map { UInt8($0 % 251) }
      var restored: [UInt8] = []
      for offset in stride(from: 0, to: size, by: 1016) {
        let bytes = StreamDeckImageReport.make(image: image, key: 2, offset: offset)
        let count = Int(bytes[4]) | (Int(bytes[5]) << 8)
        #expect(bytes.count == 1024)
        #expect(Array(bytes.prefix(3)) == [2, 7, 2])
        #expect(Int(bytes[6]) | (Int(bytes[7]) << 8) == offset / 1016)
        #expect(bytes[3] == (offset + count == size ? 1 : 0))
        #expect(bytes[(8 + count)...].allSatisfy { $0 == 0 })
        restored += bytes[8..<(8 + count)]
      }
      #expect(restored == image)
    }
  }

  @Test func malformedReportsPreserveHeldState() {
    for index in [0, 1, 2, 3, 4, 18] {
      var state = StreamDeckPressState()
      state.seed(report([0]))
      #expect(state.receive(report([0])).isEmpty)
      var malformed = report()
      malformed[index] = 0xff
      #expect(state.receive(malformed).isEmpty)
      // A malformed release must not turn a repeated held report into a press.
      #expect(state.receive(report([0])).isEmpty)
      #expect(state.receive(report()).isEmpty)
      #expect(state.receive(report([0])) == [0])
    }
  }

  @Test func malformedInitialSnapshotDoesNotConsumeFirstPress() {
    var state = StreamDeckPressState()
    var malformed = report()
    malformed[2] = 14
    state.seed(malformed)
    #expect(state.receive(report([1])).isEmpty)
    #expect(state.receive(report()) == [1])
  }

  @Test(arguments: 0..<3)
  func firstPressWorksWithoutInitialSnapshot(key: Int) {
    var state = StreamDeckPressState()
    #expect(state.receive(report([key])) == (key == 1 ? [] : [key]))
    #expect(state.receive(report([key])).isEmpty)
    #expect(state.receive(report()) == (key == 1 ? [key] : []))
  }

  @Test func startPauseFiresOnlyOnKeyUp() {
    var state = StreamDeckPressState()
    #expect(state.receive(report()).isEmpty)
    for _ in 0..<3 {
      #expect(state.receive(report([1])).isEmpty)
      for _ in 0..<100 {
        #expect(state.receive(report([1])).isEmpty)
      }
      #expect(state.receive([1, 0]).isEmpty)
      #expect(state.receive(report([1])).isEmpty)
      #expect(state.receive(report()) == [1])
      #expect(state.receive(report()).isEmpty)
    }
  }

  @Test func startPauseReleaseCannotChangeTargetOrControlState() {
    var state = StreamDeckPressState()
    #expect(state.receive(report([1]), generation: 1).isEmpty)
    // A repeated held report in a new frame must not rearm the release.
    #expect(state.receive(report([1]), generation: 2).isEmpty)
    #expect(state.receive(report(), generation: 2).isEmpty)
    #expect(state.receive(report([1]), generation: 2).isEmpty)
    #expect(state.receive(report(), generation: 2) == [1])
    // Even if the visible state returns to its old value, its generation changed.
    #expect(state.receive(report([1]), generation: 2).isEmpty)
    #expect(state.receive(report(), generation: 4).isEmpty)
  }

  @Test(arguments: [0, 2])
  func stopAndScreenshotFireOnKeyDownWithoutDelay(key: Int) {
    var state = StreamDeckPressState()
    #expect(state.receive(report()).isEmpty)
    for _ in 0..<3 {
      #expect(state.receive(report([key])) == [key])
      #expect(state.receive(report([key])).isEmpty)
      #expect(state.receive(report()).isEmpty)
    }
  }
}
