// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgramRuntime
import Testing

struct ProgramOutputProfileTests {
  @Test func sdr1080p60DerivesTheSharedEncodingContract() {
    let profile = ProgramOutputProfile.sdr1080p60
    let configuration = profile.makeSegmentedMP4Configuration()

    #expect(profile.id == "sdr-1080p60")
    #expect(configuration.width == 1_920)
    #expect(configuration.height == 1_080)
    #expect(configuration.frameRate == 60)
    #expect(configuration.videoBitRate == 6_000_000)
    #expect(configuration.audioSampleRate == 48_000)
    #expect(configuration.audioChannelCount == 2)
    #expect(configuration.audioBitRate == 128_000)
    #expect(configuration.segmentDurationSeconds == 2)
  }

}
