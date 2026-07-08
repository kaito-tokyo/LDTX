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
                    composite: composite,
                    inputDevices: [
                        WorkspaceInputDeviceRecord(
                            id: "workspace-camera",
                            name: "Game Capture",
                            kind: .video,
                            physicalDeviceID: "camera-1",
                            backgroundRemovalPolicy: .enabled
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
            ],
            programArguments: [
                SavedProgramArgumentsRecord(
                    name: "Switch 2",
                    arguments: ProgramArguments(audioChannelGainsByName: [
                        [audioChannel].audioChannelKey(for: audioChannel): -6,
                        "Mic": 3
                    ])
                )
            ],
            audioChannels: [audioChannel]
        )

        let data = try WorkspacePersistenceCodec.encodeWorkspace(workspace)
        let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: data)

        XCTAssertEqual(decoded, workspace)
    }

    func testWorkspaceJSONRoundTripsThroughProtobufPersistence() throws {
        let workspace = WorkspaceDefinition(
            id: "json-workspace",
            name: "JSON Mirror",
            programs: [
                SavedProgramDefinitionRecord(
                    name: "JSON Program",
                    canvasWidth: 1280,
                    canvasHeight: 720,
                    frameRateNumerator: 30,
                    frameRateDenominator: 1,
                    composite: CompositeProgramDefinition(),
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
            ],
            audioChannels: [
                ProgramAudioChannel(
                    component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "workspace-commentary"))
                )
            ]
        )

        let data = try WorkspacePersistenceCodec.encodeWorkspaceJSON(workspace)
        let decoded = try WorkspacePersistenceCodec.decodeWorkspaceJSON(from: data)

        XCTAssertEqual(decoded, workspace)
    }

    func testLegacyProgramAudioChannelsMigrateToWorkspaceAudioChannels() throws {
        let audioChannel = ProgramAudioChannel(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "workspace-mic"))
        )
        let legacyWorkspace = WorkspaceDefinition(
            id: "legacy-workspace",
            name: "Legacy Workspace",
            programs: [
                SavedProgramDefinitionRecord(
                    name: "Legacy Program",
                    canvasWidth: 1280,
                    canvasHeight: 720,
                    frameRateNumerator: 30,
                    frameRateDenominator: 1,
                    composite: CompositeProgramDefinition(audioChannels: [audioChannel]),
                    inputDevices: []
                )
            ]
        )

        let data = try WorkspacePersistenceCodec.encodeWorkspace(legacyWorkspace)
        let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: data)

        XCTAssertEqual(decoded.audioChannels, [audioChannel])
    }

    func testUnspecifiedAudioSideTrackPolicyRecordsByDefault() {
        let inputDevice = WorkspaceInputDeviceRecord(name: "Mic", kind: .audio)

        XCTAssertTrue(inputDevice.sideTrackRecordingPolicy.recordsSideTrack)
    }

    func testUnspecifiedBackgroundRemovalPolicyDoesNotRemoveBackgroundByDefault() {
        let inputDevice = WorkspaceInputDeviceRecord(name: "Camera", kind: .video)

        XCTAssertFalse(inputDevice.removesBackground)
    }
}
