// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import LDTXProgramRuntime

struct SessionRecordAudioTrackTests {
  @Test func everyAudioInputMappingProducesARecordingTrack() {
    let tracks = SessionRecordAudioTrack.make(
      deviceIDsByInputKey: [
        "commentary": "physical-mic",
        "game-audio": "physical-game-audio",
      ],
      deviceNamesByInputKey: [
        "commentary": "Commentary",
        "game-audio": "Game Audio",
      ]
    )

    #expect(Set(tracks.map(\.key)) == ["commentary", "game-audio"])
    #expect(Set(tracks.map(\.deviceID)) == ["physical-mic", "physical-game-audio"])
    #expect(Set(tracks.map(\.displayName)) == ["Commentary", "Game Audio"])
  }

  @Test func duplicateDisplayNamesStillProduceDistinctRecordingFiles() {
    let tracks = SessionRecordAudioTrack.make(
      deviceIDsByInputKey: ["first": "device-1", "second": "device-2"],
      deviceNamesByInputKey: ["first": "Audio", "second": "Audio"]
    )

    #expect(tracks.count == 2)
    #expect(Set(tracks.map(\.fileNameStem)).count == 2)
  }

  @Test func embeddedMainMixIdentifierIsReservedForVersionTwoPackages() {
    let tracks = SessionRecordAudioTrack.make(
      deviceIDsByInputKey: ["main-mix": "physical-main-mix"],
      deviceNamesByInputKey: ["main-mix": "Main Mix"]
    )

    #expect(tracks.map(\.trackID) == ["main-mix-2"])
  }

  @Test func mainProgramRepresentationIdentifierIsReserved() {
    let tracks = SessionRecordAudioTrack.make(
      deviceIDsByInputKey: ["main": "physical-main"],
      deviceNamesByInputKey: ["main": "Main"]
    )

    #expect(tracks.map(\.trackID) == ["main-2"])
  }
}
