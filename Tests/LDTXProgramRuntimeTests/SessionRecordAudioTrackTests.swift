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

  @Test func dualCanvasMixIdentifiersAreReserved() {
    let tracks = SessionRecordAudioTrack.make(
      deviceIDsByInputKey: [
        "landscape-mix": "landscape-device", "portrait-mix": "portrait-device",
      ],
      deviceNamesByInputKey: [:])

    #expect(Set(tracks.map(\.trackID)) == ["landscape-mix-2", "portrait-mix-2"])
  }

  @Test func collidingCanvasKeysPreserveDistinctInputDevices() {
    let tracks = SessionRecordAudioTrack.make(
      landscapeDeviceIDsByInputKey: ["microphone": "landscape-device"],
      landscapeDeviceNamesByInputKey: ["microphone": "Landscape Mic"],
      portraitDeviceIDsByInputKey: ["microphone": "portrait-device"],
      portraitDeviceNamesByInputKey: ["microphone": "Portrait Mic"])

    #expect(Set(tracks.map(\.deviceID)) == ["landscape-device", "portrait-device"])
    #expect(Set(tracks.map(\.displayName)) == ["Landscape Mic", "Portrait Mic"])
    #expect(Set(tracks.map(\.key)).count == 2)
  }

  @Test func sharedCanvasInputDeviceProducesOneSideTrack() {
    let tracks = SessionRecordAudioTrack.make(
      landscapeDeviceIDsByInputKey: ["landscape": "shared-device"],
      landscapeDeviceNamesByInputKey: ["landscape": "Shared Mic"],
      portraitDeviceIDsByInputKey: ["portrait": "shared-device"],
      portraitDeviceNamesByInputKey: ["portrait": "Shared Mic"])

    #expect(tracks.count == 1)
    #expect(tracks.first?.deviceID == "shared-device")
  }
}
