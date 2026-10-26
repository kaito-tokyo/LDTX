// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import Testing

@Suite
struct ProgramPreferencesUnitTestSuite {
  @Test("LUB-1001: Video layer visibility is scoped to the program layer")
  func videoLayerVisibilityIsScopedToTheProgramLayer() {
    let preferences = ProgramPreferences(videoLayersByProgramName: [
      "Program A": [VideoLayerPreference(componentName: "Camera", isHidden: true)],
      "Program B": [VideoLayerPreference(componentName: "Camera", isHidden: false)],
    ])

    #expect(preferences.isVideoLayerHidden(componentName: "Camera", programName: "Program A"))
    #expect(!preferences.isVideoLayerHidden(componentName: "Camera", programName: "Program B"))
    #expect(!preferences.isVideoLayerHidden(componentName: "Missing", programName: "Program A"))
  }

  @Test("LUB-1001: Input device rename and removal update direct video layers")
  func inputDeviceRenameAndRemovalUpdateDirectVideoLayers() {
    var preferences = ProgramPreferences(videoLayersByProgramName: [
      "Program": [
        VideoLayerPreference(componentName: "Camera A", isHidden: true),
        VideoLayerPreference(componentName: "Title"),
      ]
    ])

    preferences.renameInputDevice(from: "Camera A", to: "Camera B")
    #expect(
      preferences.videoLayers(forProgramNamed: "Program").map(\.componentName) == [
        "Camera B", "Title",
      ])
    #expect(preferences.isVideoLayerHidden(componentName: "Camera B", programName: "Program"))

    preferences.removeInputDevice(named: "Camera B")
    #expect(preferences.videoLayers(forProgramNamed: "Program").map(\.componentName) == ["Title"])
  }

  @Test("LUB-1001: Video layer removal can be scoped to one program")
  func videoLayerRemovalCanBeScopedToOneProgram() {
    var preferences = ProgramPreferences(videoLayersByProgramName: [
      "Program A": [VideoLayerPreference(componentName: "Camera")],
      "Program B": [VideoLayerPreference(componentName: "Camera")],
    ])

    preferences.removeVideoComponentReference(
      named: "Camera", fromProgramNamed: "Program A")

    #expect(preferences.videoLayers(forProgramNamed: "Program A").isEmpty)
    #expect(
      preferences.videoLayers(forProgramNamed: "Program B") == [
        VideoLayerPreference(componentName: "Camera")
      ])
  }

  @Test("LUB-1001: Audio mute preserves the configured gain")
  func audioMutePreservesTheConfiguredGain() {
    let channel = ProgramAudioChannel(
      name: "Microphone",
      component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "1-Mic"))
    )
    var preferences = ProgramPreferences()
    preferences.setAudioChannelGain(0.5, for: channel, in: [channel])
    preferences.setAudioMuted(true, inputDeviceName: "1-Mic")

    #expect(preferences.audioChannelGain(for: channel, in: [channel]) == 0.5)
    #expect(preferences.outputAudioChannelGain(for: channel, in: [channel]) == 0)

    preferences.setAudioMuted(false, inputDeviceName: "1-Mic")
    #expect(preferences.outputAudioChannelGain(for: channel, in: [channel]) == 0.5)
  }

  private let firstID = "First"
  private let secondID = "Second"

  @Test("LUB-1001: Video visibility uses canonical percent encoded input device name")
  func videoVisibilityUsesCanonicalPercentEncodedInputDeviceName() {
    var preferences = ProgramPreferences()

    preferences.setVideoHidden(true, inputDeviceName: "Camera 端末/%")

    #expect(preferences.videoHiddenByInputDeviceName == ["Camera%20%E7%AB%AF%E6%9C%AB%2F%25": true])
    #expect(preferences.isVideoHidden(inputDeviceName: "Camera 端末/%"))
  }

  @Test("LUB-1001: Explicit visibility is stored and rename moves the entry")
  func explicitVisibilityIsStoredAndRenameMovesTheEntry() {
    var preferences = ProgramPreferences()
    preferences.setVideoHidden(false, inputDeviceName: "Camera A")

    preferences.renameInputDevice(from: "Camera A", to: "Camera B")

    #expect(preferences.videoHiddenByInputDeviceName == ["Camera%20B": false])
    #expect(!preferences.isVideoHidden(inputDeviceName: "Camera A"))
    #expect(!preferences.isVideoHidden(inputDeviceName: "Camera B"))
  }

  @Test("LUB-1001: Rename with conflicting audio mute keys clears audio mute preferences")
  func renameWithConflictingAudioMuteKeysClearsAudioMutePreferences() {
    var preferences = ProgramPreferences()
    preferences.setAudioMuted(true, inputDeviceName: "Camera A")
    preferences.setAudioMuted(false, inputDeviceName: "Camera B")

    preferences.renameInputDevice(from: "Camera A", to: "Camera B")

    #expect(preferences.audioMutedByInputDeviceName.isEmpty)
  }

  @Test("LUB-1001: Audio channel gain decibel conversion uses expected range")
  func audioChannelGainDecibelConversionUsesExpectedRange() {
    #expect(
      abs(ProgramPreferences.linearAudioChannelGain(fromDecibels: -80) - 0.0001) <= 0.000_000_1)
    #expect(abs(ProgramPreferences.linearAudioChannelGain(fromDecibels: 0) - 1.0) <= 0.000_000_1)
    #expect(abs(ProgramPreferences.linearAudioChannelGain(fromDecibels: 20) - 10.0) <= 0.000_000_1)
  }

  @Test("LUB-1001: Audio channel gain clamps to minus80 through plus20 decibels")
  func audioChannelGainClampsToMinus80ThroughPlus20Decibels() {
    #expect(
      abs(
        ProgramPreferences.clampedAudioChannelGain(0) - ProgramPreferences.minimumAudioChannelGain)
        <= 0.000_000_1)
    #expect(
      abs(
        ProgramPreferences.clampedAudioChannelGain(100) - ProgramPreferences.maximumAudioChannelGain
      ) <= 0.000_000_1)
    #expect(ProgramPreferences.clampedAudioChannelGain(.nan) == 1.0)
  }

  @Test("LUB-1001: Set audio channel gain stores clamped linear gain")
  func setAudioChannelGainStoresClampedLinearGain() throws {
    let composite = CompositeProgramDefinition(audioChannels: [
      ProgramAudioChannel(
        id: firstID,
        component: .inputAudioDevice(InputAudioDeviceComponent())
      )
    ])
    let channel = composite.audioChannels[0]
    var preferences = ProgramPreferences()

    preferences.setAudioChannelGain(100, for: channel, in: composite)

    let gain = try #require(
      preferences.audioChannelGainsByName[composite.audioChannelKey(for: channel)])
    #expect(abs(gain - ProgramPreferences.maximumAudioChannelGain) <= 0.000_000_1)
  }

  @Test(
    "LUB-1001: Resolved workspace audio channels derive input audio channels from workspace input devices"
  ) func resolvedWorkspaceAudioChannelsDeriveInputAudioChannelsFromWorkspaceInputDevices()
    throws
  {
    let workspaceInputDevices = [
      ProgramInputDeviceRecord(
        name: "Desk Mic",
        kind: .audio
      )
    ]

    let resolvedChannels = workspaceInputDevices.resolvedWorkspaceAudioChannels(from: [])

    #expect(resolvedChannels.count == 1)
    let channel = try #require(resolvedChannels.first)
    guard case .inputAudioDevice(let payload) = channel.component else {
      Issue.record("Expected an input audio device channel.")
      return
    }
    #expect(payload.inputDeviceID == "Desk Mic")
    #expect(
      workspaceInputDevices.resolvedWorkspaceAudioChannels(from: [])[0].id == resolvedChannels[0].id
    )
  }

  @Test(
    "LUB-1001: Resolved workspace audio channels drop stale input device channels but keep generated audio"
  ) func resolvedWorkspaceAudioChannelsDropStaleInputDeviceChannelsButKeepGeneratedAudio() {
    let liveChannel = ProgramAudioChannel(
      id: firstID,
      component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "Desk Mic"))
    )
    let staleChannel = ProgramAudioChannel(
      id: secondID,
      component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "Missing Mic"))
    )
    let silentChannel = ProgramAudioChannel(component: .silentAudio)
    let workspaceInputDevices = [
      ProgramInputDeviceRecord(
        name: "Desk Mic",
        kind: .audio
      )
    ]

    let resolvedChannels = workspaceInputDevices.resolvedWorkspaceAudioChannels(
      from: [liveChannel, staleChannel, silentChannel]
    )

    #expect(resolvedChannels.count == 2)
    #expect(resolvedChannels[0] == liveChannel)
    #expect(resolvedChannels[1] == silentChannel)
  }
}
