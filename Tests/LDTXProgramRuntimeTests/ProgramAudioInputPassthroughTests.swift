// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import LDTXProgramRuntime

struct ProgramAudioInputPassthroughTests {
  @Test func emptyMonitorCanBeStoppedAndReconfiguredWithoutHardware() throws {
    let monitor = ProgramAudioInputPassthrough()
    try monitor.configure(deviceUIDsByKey: [:], gainsByKey: [:], enabledKeys: [], masterGain: 1)
    monitor.updateGains([:], enabledChannelKeys: [], masterGain: 2)
    monitor.stop()
    monitor.stop()
    #expect(monitor.channelIdentities.isEmpty)
  }
}
