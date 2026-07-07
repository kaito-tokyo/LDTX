// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import XCTest

final class WorkspacePersistenceCodecTests: XCTestCase {
    func testWorkspaceRoundTripsThroughProtobufPersistence() throws {
        let videoStep = CompositeProgramStep(
            component: .inputCameraDevice(InputDeviceComponent(
                destinationScale: 0.85
            ))
        )
        let audioChannel = ProgramAudioChannel(
            component: .inputAudioDevice(InputAudioDeviceComponent())
        )
        var composite = CompositeProgramDefinition(
            steps: [videoStep],
            audioChannels: [audioChannel]
        )
        composite.programVideoPTSInputKey = composite.inputCameraDeviceMappingKey(for: videoStep)
        composite.programAudioPTSInputKey = composite.audioChannelKey(for: audioChannel)

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
                    composite: composite
                )
            ],
            programArguments: [
                SavedProgramArgumentsRecord(
                    name: "Switch 2",
                    arguments: ProgramArguments(audioChannelGainsByName: [
                        composite.audioChannelKey(for: audioChannel): -6,
                        "Mic": 3
                    ])
                )
            ],
            inputDevices: [
                WorkspaceInputDeviceRecord(
                    id: "workspace-camera",
                    name: "Game Capture",
                    kind: .video,
                    physicalDeviceID: "camera-1"
                ),
                WorkspaceInputDeviceRecord(
                    id: "workspace-game-audio",
                    name: "Game Audio",
                    kind: .audio,
                    physicalDeviceID: "audio-1"
                ),
                WorkspaceInputDeviceRecord(
                    id: "workspace-mic",
                    name: "Mic",
                    kind: .audio,
                    physicalDeviceID: "audio-2",
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
                WorkspaceInputDeviceRecord(
                    id: "workspace-camera",
                    name: "Camera",
                    kind: .video,
                    physicalDeviceID: "camera-1"
                ),
                WorkspaceInputDeviceRecord(
                    id: "workspace-commentary",
                    name: "Commentary",
                    kind: .audio,
                    physicalDeviceID: "audio-1"
                )
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
