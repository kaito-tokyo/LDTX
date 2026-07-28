// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import Testing

struct ProgramPersistenceCodecTests {
    @Test func emptyClockProtobufUsesDomainDefaults() {
        var proto = Ldtx_Program_V1_ProgramComponent()
        proto.clock = Ldtx_Program_V1_ClockComponent()

        #expect(
            ProgramPersistenceCodec.decodeProgramComponent(proto) ==
                .clock(ClockComponent())
        )
    }

    @Test func clockProtobufPreservesExplicitFalsePresentationSettings() {
        var clock = Ldtx_Program_V1_ClockComponent()
        clock.showsSeconds = false
        clock.uses24HourTime = false
        var proto = Ldtx_Program_V1_ProgramComponent()
        proto.clock = clock

        let decoded = ProgramPersistenceCodec.decodeProgramComponent(proto)
        guard case let .clock(component) = decoded else {
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
                    component: .inputCameraDevice(InputDeviceComponent(
                        inputDeviceID: "workspace-camera",
                        sourceCropTop: 0.1,
                        sourceCropRight: 0.2,
                        sourceCropBottom: 0.3,
                        sourceCropLeft: 0.4,
                        destinationX: 0.25,
                        destinationY: 0.5,
                        destinationScale: 1.25,
                        removesBackground: true
                    ))
                ),
                CompositeProgramStep(
                    component: .fillSolidColor(FillSolidColorComponent(
                        red: 0.9,
                        green: 0.1,
                        blue: 0.2,
                        alpha: 0.8,
                        clip: FillClip(top: 0.01, right: 0.02, bottom: 0.03, left: 0.04)
                    ))
                ),
                CompositeProgramStep(
                    component: .fillLinearGradient(FillLinearGradientComponent(
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
                    component: .fillRadialGradient(FillRadialGradientComponent(
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
                    component: .fillConicGradient(FillConicGradientComponent(
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
                    component: .clock(ClockComponent(
                        destinationX: 0.6,
                        destinationY: 0.08,
                        destinationWidth: 0.3,
                        destinationHeight: 0.14,
                        showsSeconds: false,
                        uses24HourTime: true,
                        foregroundRed: 0.9,
                        foregroundGreen: 0.8,
                        foregroundBlue: 0.7,
                        foregroundAlpha: 1,
                        backgroundRed: 0.1,
                        backgroundGreen: 0.2,
                        backgroundBlue: 0.3,
                        backgroundAlpha: 0.5
                    ))
                ),
                CompositeProgramStep(component: .testPattern)
            ],
            audioChannels: [
                ProgramAudioChannel(
                    component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "workspace-mic"))
                ),
                ProgramAudioChannel(component: .silentAudio),
                ProgramAudioChannel(component: .testPatternAudio)
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
        let firstChannel = ProgramAudioChannel(component: .inputAudioDevice(InputAudioDeviceComponent()))
        let secondChannel = ProgramAudioChannel(component: .testPatternAudio)
        let composite = CompositeProgramDefinition(audioChannels: [firstChannel, secondChannel])
        let preferences = ProgramPreferences(
            audioChannelGainsByName: [
                composite.audioChannelKey(for: firstChannel): 0.75,
                composite.audioChannelKey(for: secondChannel): 0.25
            ],
            videoMutedByInputDeviceName: ["Camera%201": true]
        )

        let data = try ProgramPersistenceCodec.encodeProgramPreferences(preferences)
        let decoded = try ProgramPersistenceCodec.decodeProgramPreferences(from: data)

        #expect(decoded == preferences)
    }
}
