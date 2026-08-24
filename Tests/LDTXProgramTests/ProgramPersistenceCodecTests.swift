// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import Testing

struct ProgramPersistenceCodecTests {
  @Test func inputDestinationDecodesLegacyUniformScale() throws {
    let data = Data(#"{"x":120,"y":80,"scale":1.5}"#.utf8)

    let destination = try JSONDecoder().decode(InputDeviceDestination.self, from: data)

    #expect(destination.x == 120)
    #expect(destination.y == 80)
    #expect(destination.scaleX == 1.5)
    #expect(destination.scaleY == 1.5)
  }

  @Test func clockCSSBackgroundValidationUsesRenderingGrammar() throws {
    #expect(ClockCSSBackground.isValid(""))
    #expect(ClockCSSBackground.isValid("#10203080"))
    #expect(ClockCSSBackground.isValid("rgba(16, 32, 48, 0.5)"))
    #expect(ClockCSSBackground.isValid("linear-gradient(90deg, #102030, transparent)"))
    #expect(!ClockCSSBackground.isValid("not-a-background"))
    #expect(!ClockCSSBackground.isValid("linear-gradient(nandeg, #000, #fff)"))
    #expect(!ClockCSSBackground.isValid("linear-gradient(infdeg, #000, #fff)"))

    let empty = try #require(ClockCSSBackground.parse(""))
    #expect(empty == .solid(.clear))
  }

  @Test func emptyClockProtobufUsesDomainDefaults() {
    var proto = Ldtx_Program_V1_ProgramComponent()
    proto.clock = Ldtx_Program_V1_ClockComponent()

    #expect(
      ProgramPersistenceCodec.decodeProgramComponent(proto) == .clock(ClockComponent())
    )
  }

  @Test func clockProtobufPreservesExplicitFalsePresentationSettings() {
    var clock = Ldtx_Program_V1_ClockComponent()
    clock.showsSeconds = false
    clock.uses24HourTime = false
    var proto = Ldtx_Program_V1_ProgramComponent()
    proto.clock = clock

    let decoded = ProgramPersistenceCodec.decodeProgramComponent(proto)
    guard case .clock(let component) = decoded else {
      Issue.record("Expected a Clock component.")
      return
    }
    #expect(!component.showsSeconds)
    #expect(!component.uses24HourTime)
    #expect(component.destinationWidth == ClockComponent().destinationWidth)
    #expect(component.foregroundAlpha == ClockComponent().foregroundAlpha)
    #expect(component.backgroundAlpha == ClockComponent().backgroundAlpha)
  }

  @Test func programDefinitionRecordsRoundTripThroughProtobufPersistence() throws {
    let composite = CompositeProgramDefinition(
      steps: [
        CompositeProgramStep(
          displayName: "Game Capture",
          component: .inputCameraDevice(
            InputDeviceComponent(
              inputDeviceID: "workspace-camera",
              sourceCropTop: 0.1,
              sourceCropRight: 0.2,
              sourceCropBottom: 0.3,
              sourceCropLeft: 0.4,
              removesBackground: true
            ))
        ),
        CompositeProgramStep(
          component: .fillSolidColor(
            FillSolidColorComponent(
              red: 0.9,
              green: 0.1,
              blue: 0.2,
              alpha: 0.8,
              clip: FillClip(top: 0.01, right: 0.02, bottom: 0.03, left: 0.04)
            ))
        ),
        CompositeProgramStep(
          component: .fillLinearGradient(
            FillLinearGradientComponent(
              startX: 0.1,
              startY: 0.2,
              endX: 0.8,
              endY: 0.9,
              startRed: 0.1,
              startGreen: 0.2,
              startBlue: 0.3,
              startAlpha: 0.4,
              endRed: 0.5,
              endGreen: 0.6,
              endBlue: 0.7,
              endAlpha: 0.8,
              clip: FillClip(top: 0.11, right: 0.12, bottom: 0.13, left: 0.14)
            ))
        ),
        CompositeProgramStep(
          component: .fillRadialGradient(
            FillRadialGradientComponent(
              centerX: 0.45,
              centerY: 0.55,
              innerRadius: 0.2,
              outerRadius: 0.7,
              innerRed: 0.2,
              innerGreen: 0.3,
              innerBlue: 0.4,
              innerAlpha: 0.5,
              outerRed: 0.6,
              outerGreen: 0.7,
              outerBlue: 0.8,
              outerAlpha: 0.9,
              clip: FillClip(top: 0.21, right: 0.22, bottom: 0.23, left: 0.24)
            ))
        ),
        CompositeProgramStep(
          component: .fillConicGradient(
            FillConicGradientComponent(
              centerX: 0.4,
              centerY: 0.6,
              startAngleRadians: 1.5,
              startRed: 0.3,
              startGreen: 0.4,
              startBlue: 0.5,
              startAlpha: 0.6,
              endRed: 0.7,
              endGreen: 0.8,
              endBlue: 0.9,
              endAlpha: 1,
              clip: FillClip(top: 0.31, right: 0.32, bottom: 0.33, left: 0.34)
            ))
        ),
        CompositeProgramStep(
          displayName: "Local Clock",
          component: .clock(
            ClockComponent(
              showsSeconds: false,
              uses24HourTime: true,
              foregroundRed: 0.9,
              foregroundGreen: 0.8,
              foregroundBlue: 0.7,
              foregroundAlpha: 1,
              backgroundRed: 0.1,
              backgroundGreen: 0.2,
              backgroundBlue: 0.3,
              backgroundAlpha: 0.5,
              showsDate: true,
              usesSystemTimeZone: false,
              utcOffsetMinutes: 345,
              background: "linear-gradient(90deg, #101828, #344054)",
              outlines: [
                ClockTextOutline(thickness: 2, color: "#000000"),
                ClockTextOutline(thickness: 1, color: "#ff0000"),
              ]
            ))
        ),
        CompositeProgramStep(component: .testPattern),
      ],
      audioChannels: [
        ProgramAudioChannel(
          component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "workspace-mic"))
        ),
        ProgramAudioChannel(component: .silentAudio),
        ProgramAudioChannel(component: .testPatternAudio),
      ]
    )

    let records = [
      SavedProgramDefinitionRecord(
        name: "Studio Program",
        canvasWidth: 1920,
        canvasHeight: 1080,
        frameRateNumerator: 60000,
        frameRateDenominator: 1001,
        composite: composite,
        inputDevices: [
          ProgramInputDeviceRecord(
            name: "workspace-camera",
            kind: .video,
            physicalDeviceID: "camera-1",
            colorRangePolicy: .fullRange,
            captureWidthOverride: 1280,
            captureHeightOverride: 720,
            captureFrameRateOverride: 30
          ),
          ProgramInputDeviceRecord(
            name: "Mic",
            kind: .audio,
            physicalDeviceID: "audio-2"
          ),
        ]
      )
    ]

    let data = try ProgramPersistenceCodec.encodeProgramDefinitions(records)
    let decoded = try ProgramPersistenceCodec.decodeProgramDefinitions(from: data)

    #expect(decoded == records)
  }

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

  @Test func componentDefinitionsDoNotPersistVideoLayerPlacement() {
    let input = ProgramPersistenceCodec.decodeProgramComponent(
      ProgramPersistenceCodec.encodeProgramComponent(
        .inputCameraDevice(
          InputDeviceComponent(
            destinationX: 120,
            destinationY: 80,
            destinationScale: 1.5
          )))
    )
    guard case .inputCameraDevice(let inputPayload) = input else {
      Issue.record("Expected Input Device")
      return
    }
    #expect(inputPayload.destination == InputDeviceDestination())

    let clock = ProgramPersistenceCodec.decodeProgramComponent(
      ProgramPersistenceCodec.encodeProgramComponent(
        .clock(
          ClockComponent(
            destinationX: 0.2,
            destinationY: 0.3,
            destinationWidth: 0.4,
            destinationHeight: 0.5
          )))
    )
    guard case .clock(let clockPayload) = clock else {
      Issue.record("Expected Clock")
      return
    }
    #expect(clockPayload.destinationX == ClockComponent().destinationX)
    #expect(clockPayload.destinationY == ClockComponent().destinationY)
    #expect(clockPayload.destinationWidth == ClockComponent().destinationWidth)
    #expect(clockPayload.destinationHeight == ClockComponent().destinationHeight)
  }
}
