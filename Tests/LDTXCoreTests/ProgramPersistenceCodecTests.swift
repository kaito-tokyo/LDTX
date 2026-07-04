// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import XCTest

final class ProgramPersistenceCodecTests: XCTestCase {
    func testProgramDefinitionRecordsRoundTripThroughProtobufPersistence() throws {
        let records = [
            SavedProgramDefinitionRecord(
                name: "Studio Program",
                canvasWidth: 1920,
                canvasHeight: 1080,
                frameRateNumerator: 60000,
                frameRateDenominator: 1001,
                composite: CompositeProgramDefinition(
                    steps: [
                        CompositeProgramStep(
                            name: "Camera",
                            component: .inputCameraDevice(InputDeviceComponent(
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
                            name: "Solid",
                            component: .fillSolidColor(FillSolidColorComponent(
                                red: 0.9,
                                green: 0.1,
                                blue: 0.2,
                                alpha: 0.8,
                                clip: FillClip(top: 0.01, right: 0.02, bottom: 0.03, left: 0.04)
                            ))
                        ),
                        CompositeProgramStep(
                            name: "Linear",
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
                            name: "Radial",
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
                            name: "Conic",
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
                        CompositeProgramStep(name: "Pattern", component: .testPattern)
                    ],
                    programVideoPTSInputKey: "Camera",
                    programAudioPTSInputKey: "Mic",
                    audioChannels: [
                        ProgramAudioChannel(name: "Mic", component: .inputAudioDevice(InputAudioDeviceComponent())),
                        ProgramAudioChannel(name: "Mute", component: .silentAudio),
                        ProgramAudioChannel(name: "Tone", component: .testPatternAudio)
                    ]
                )
            )
        ]

        let data = try ProgramPersistenceCodec.encodeProgramDefinitions(records)
        let decoded = try ProgramPersistenceCodec.decodeProgramDefinitions(from: data)

        XCTAssertEqual(decoded, records)
    }

    func testProgramArgumentsRecordsRoundTripThroughProtobufPersistence() throws {
        let records = [
            SavedProgramArgumentsRecord(
                name: "Studio Program",
                arguments: ProgramArguments(audioChannelGainsByName: [
                    "Mic": 0.75,
                    "Tone": 0.25
                ])
            )
        ]

        let data = try ProgramPersistenceCodec.encodeProgramArguments(records)
        let decoded = try ProgramPersistenceCodec.decodeProgramArguments(from: data)

        XCTAssertEqual(decoded, records)
    }
}
