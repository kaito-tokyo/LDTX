// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import Foundation
import LDTXAudioEngine
@testable import LDTXProgramRuntime
import Testing

@Suite
struct ProgramAudioInputPassthroughUnitTestSuite {
  @Test func monitorReconfigurationPreservesInputGeneration() {
    let engine = WorkspaceAudioEngine(hardwareEnabled: false)
    let input = engine.input(uid: "test", kind: 3)
    let generation = LDTXAudioGetStatistics(engine.native, input).generation
    for connected in [true, false, true] {
      engine.configureMonitor(
        routes: [.init(input: input, gain: 2, connected: connected)], master: 3)
      #expect(LDTXAudioGetStatistics(engine.native, input).generation == generation)
    }
  }
}
