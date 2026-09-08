// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import Foundation
import LDTXAudioEngine
import Testing

@testable import LDTXProgramRuntime

struct ProgramAudioInputPassthroughTests {
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
