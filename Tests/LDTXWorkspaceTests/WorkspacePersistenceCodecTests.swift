// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import XCTest

final class WorkspacePersistenceCodecTests: XCTestCase {
    func testWorkspaceRoundTripsThroughProtobufPersistence() throws {
        let workspace = WorkspaceDefinition(
            id: "workspace-id",
            name: "Streaming Setup",
            programs: [
                SavedProgramDefinitionRecord(
                    name: "Switch 2",
                    canvasWidth: 1920,
                    canvasHeight: 1080,
                    frameRateNumerator: 60,
                    frameRateDenominator: 1,
                    composite: CompositeProgramDefinition(
                        steps: [
                            CompositeProgramStep(
                                name: "Game Capture",
                                component: .inputCameraDevice(InputDeviceComponent(
                                    destinationScale: 0.85
                                ))
                            )
                        ],
                        programVideoPTSInputKey: "Game Capture",
                        programAudioPTSInputKey: "Game Audio",
                        audioChannels: [
                            ProgramAudioChannel(
                                name: "Game Audio",
                                component: .inputAudioDevice(InputAudioDeviceComponent())
                            )
                        ]
                    )
                )
            ],
            programArguments: [
                SavedProgramArgumentsRecord(
                    name: "Switch 2",
                    arguments: ProgramArguments(audioChannelGainsByName: [
                        "Game Audio": -6,
                        "Mic": 3
                    ])
                )
            ],
            inputDevices: [
                WorkspaceInputDeviceRecord(name: "Game Capture", kind: .video),
                WorkspaceInputDeviceRecord(name: "Game Audio", kind: .audio),
                WorkspaceInputDeviceRecord(
                    name: "Mic",
                    kind: .audio,
                    sideTrackRecordingPolicy: .disabled
                )
            ]
        )

        let data = try WorkspacePersistenceCodec.encodeWorkspace(workspace)
        let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: data)

        XCTAssertEqual(decoded, workspace)
    }

    func testWorkspaceJSONRoundTripsThroughProtobufPersistence() throws {
        let workspace = WorkspaceDefinition(
            id: "json-workspace",
            name: "JSON Mirror",
            inputDevices: [
                WorkspaceInputDeviceRecord(name: "Camera", kind: .video),
                WorkspaceInputDeviceRecord(name: "Commentary", kind: .audio)
            ]
        )

        let data = try WorkspacePersistenceCodec.encodeWorkspaceJSON(workspace)
        let decoded = try WorkspacePersistenceCodec.decodeWorkspaceJSON(from: data)

        XCTAssertEqual(decoded, workspace)
    }

    func testUnspecifiedAudioSideTrackPolicyRecordsByDefault() {
        let inputDevice = WorkspaceInputDeviceRecord(name: "Mic", kind: .audio)

        XCTAssertTrue(inputDevice.sideTrackRecordingPolicy.recordsSideTrack)
    }
}
