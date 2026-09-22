// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import Testing

@Suite
struct ProgramPreferencesPersistenceUnitTestSuite {
  @Test func programPreferencesRoundTripThroughProtobufPersistence() throws {
    let firstChannel = ProgramAudioChannel(
      component: .inputAudioDevice(InputAudioDeviceComponent()))
    let secondChannel = ProgramAudioChannel(component: .testPatternAudio)
    let composite = CompositeProgramDefinition(audioChannels: [firstChannel, secondChannel])
    let preferences = ProgramPreferences(
      audioChannelGainsByName: [
        composite.audioChannelKey(for: firstChannel): 0.75,
        composite.audioChannelKey(for: secondChannel): 0.25,
      ],
      videoMutedByInputDeviceName: ["Camera%201": true]
    )

    let data = try ProgramPersistenceCodec.encodeProgramPreferences(preferences)
    let decoded = try ProgramPersistenceCodec.decodeProgramPreferences(from: data)

    #expect(decoded == preferences)
  }

  @Test func videoLayerPreferencesRoundTripThroughProtobufPersistence() throws {
    let preferences = ProgramPreferences(videoLayersByProgramName: [
      "Main": [
        VideoLayerPreference(
          componentName: "Clock",
          destinationX: 120,
          destinationY: 80,
          destinationScaleX: 1.5,
          destinationScaleY: 0.75
        )
      ]
    ])
    let decoded = try ProgramPersistenceCodec.decodeProgramPreferences(
      from: ProgramPersistenceCodec.encodeProgramPreferences(preferences)
    )
    #expect(decoded.videoLayersByProgramName == preferences.videoLayersByProgramName)
  }

  @Test func legacyUniformVideoLayerScaleDecodesForBothAxes() throws {
    var destination = Ldtx_Program_V1_Destination()
    destination.x = 120
    destination.y = 80
    destination.scale = 1.5
    var layer = Ldtx_Program_Persistence_V1_VideoLayerPreference()
    layer.componentName = "Camera"
    layer.destination = destination
    var layers = Ldtx_Program_Persistence_V1_VideoLayerPreferences()
    layers.layers = [layer]
    var preferences = Ldtx_Program_Persistence_V1_ProgramPreferences()
    preferences.videoLayersByProgramName = ["Main": layers]

    let decoded = try ProgramPersistenceCodec.decodeProgramPreferences(
      from: preferences.serializedData()
    )
    let decodedLayer = try #require(decoded.videoLayers(forProgramNamed: "Main").first)
    #expect(decodedLayer.destinationX == 120)
    #expect(decodedLayer.destinationY == 80)
    #expect(decodedLayer.destinationScaleX == 1.5)
    #expect(decodedLayer.destinationScaleY == 1.5)
  }
}
