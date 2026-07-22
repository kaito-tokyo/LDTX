// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXWorkspace
import SwiftProtobuf
import Testing

struct WorkspacePersistenceCodecTests {
    @Test func workspaceRoundTripsThroughProtobufPersistence() throws {
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

        let workspace = WorkspaceDefinition(
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
            inputDevices: [
                WorkspaceInputDeviceRecord(
                    id: "Game Capture",
                    name: "Game Capture",
                    kind: .video,
                    backgroundRemovalPolicy: .enabled,
                    captureWidthOverride: 1280,
                    captureHeightOverride: 720,
                    captureFrameRateOverride: 30
                ),
                WorkspaceInputDeviceRecord(
                    id: "Game Audio",
                    name: "Game Audio",
                    kind: .audio,
                ),
                WorkspaceInputDeviceRecord(
                    id: "Mic",
                    name: "Mic",
                    kind: .audio
                )
            ],
            audioChannels: [audioChannel],
            visions: [
                WorkspaceVisionDefinition(
                    id: "Scene Analyzer",
                    name: "Scene Analyzer",
                    source: .inputDevice(name: "Game Capture"),
                    model: WorkspaceVisionModel(repositoryID: "mlx-community/Qwen3-VL-2B-Instruct-4bit"),
                    systemPrompt: "Return a concise scene description.",
                    userPrompt: "Describe this frame.",
                    updateIntervalSeconds: 2,
                    stopsAtNewline: true,
                    postActionAutomationName: "Analyze Periodically"
                )
            ],
            automations: [
                WorkspaceAutomationDefinition(
                    id: "automation-1",
                    name: "Analyze Periodically",
                    trigger: .interval(seconds: 5),
                    actions: [
                        .analyzeVision(visionName: "Scene Analyzer"),
                        .selectInputDevice(inputDeviceName: "Game Capture")
                    ]
                ),
                WorkspaceAutomationDefinition(
                    id: "Analyze Periodically",
                    name: "React to Vision",
                    isEnabled: false,
                    trigger: .manual
                )
            ]
        )

        let data = try WorkspacePersistenceCodec.encodeWorkspace(workspace)
        let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: data)

        #expect(decoded == workspace)
    }

    @Test func workspacePreferencesRoundTripSeparatelyFromDefinition() throws {
        let preferences = WorkspacePreferences(
            programPreferences: ProgramPreferences(
                audioChannelGainsByName: ["mic": 0.5],
                videoMutedByInputDeviceName: ["Camera": false]
            ),
            physicalDeviceIDsByInputDeviceID: ["camera": "physical-camera"],
            inputCameraDeviceMappings: ["camera-step": "physical-camera"],
            inputAudioDeviceMappings: ["audio-channel": "physical-audio"],
            inputAudioMonitorChannelKeys: ["audio-channel"],
            selectedProgramName: "Switch 2",
            output: WorkspaceOutputPreferences(
                captureOutputMode: "record",
                streamTitle: "Test",
                localOutputBaseDirectoryPath: "/tmp/output",
                recordingEnabled: true,
                youtubeEnabled: false
            )
        )

        let data = try WorkspacePersistenceCodec.encodePreferences(preferences)

        #expect(try WorkspacePersistenceCodec.decodePreferences(from: data) == preferences)
    }

    @Test func encodingRejectsDuplicateResourceNamesAcrossKinds() {
        let workspace = WorkspaceDefinition(
            inputDevices: [WorkspaceInputDeviceRecord(name: "Shared", kind: .video)],
            visions: [WorkspaceVisionDefinition(name: "Shared")]
        )

        #expect(throws: WorkspaceResourceNameValidationError.duplicateName("Shared")) {
            try WorkspacePersistenceCodec.encodeWorkspace(workspace)
        }
    }

    @Test func decodingRejectsDuplicateResourceNamesAcrossKinds() throws {
        var inputDevice = Ldtx_Workspace_V1_InputDeviceRecord()
        inputDevice.name = "Shared"
        var vision = Ldtx_Workspace_V1_VisionRecord()
        vision.name = "Shared"
        var proto = Ldtx_Workspace_V1_Workspace()
        proto.inputDevices = [inputDevice]
        proto.visions = [vision]

        #expect(throws: WorkspaceResourceNameValidationError.duplicateName("Shared")) {
            try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())
        }
    }

    @Test func legacyVisionPromptMigratesToSystemPrompt() throws {
        var vision = Ldtx_Workspace_V1_VisionRecord()
        vision.name = "Legacy Vision"
        vision.currentProgramOutput = true
        vision.prompt = "Legacy classification rules"

        var proto = Ldtx_Workspace_V1_Workspace()
        proto.name = "Legacy Workspace"
        proto.visions = [vision]

        let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())

        #expect(decoded.visions.first?.systemPrompt == "Legacy classification rules")
        #expect(decoded.visions.first?.userPrompt == WorkspaceVisionDefinition.defaultUserPrompt)
    }

    @Test func workspaceJSONRoundTripsThroughProtobufPersistence() throws {
        let videoStep = CompositeProgramStep(
            component: .inputCameraDevice(InputDeviceComponent(inputDeviceID: "Game Capture"))
        )
        let workspace = WorkspaceDefinition(
            name: "JSON Mirror",
            programs: [
                SavedProgramDefinitionRecord(
                    name: "JSON Program",
                    canvasWidth: 1280,
                    canvasHeight: 720,
                    frameRateNumerator: 30,
                    frameRateDenominator: 1,
                    composite: CompositeProgramDefinition(steps: [videoStep])
                )
            ],
            inputDevices: [
                WorkspaceInputDeviceRecord(
                    id: "Game Capture",
                    name: "Camera",
                    kind: .video,
                    captureWidthOverride: 1280,
                    captureHeightOverride: 720,
                    captureFrameRateOverride: 30
                ),
                WorkspaceInputDeviceRecord(
                    id: "Commentary",
                    name: "Commentary",
                    kind: .audio,
                )
            ],
            audioChannels: [
                ProgramAudioChannel(
                    component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "Commentary"))
                )
            ]
        )

        let data = try WorkspacePersistenceCodec.encodeWorkspaceJSON(workspace)
        let decoded = try WorkspacePersistenceCodec.decodeWorkspaceJSON(from: data)

        #expect(decoded == workspace)
    }

    @Test func legacyProgramAudioChannelsMigrateToWorkspaceAudioChannels() throws {
        let audioChannel = ProgramAudioChannel(
            name: "Mic",
            component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "Mic"))
        )
        let legacyWorkspace = WorkspaceDefinition(
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

        #expect(decoded.audioChannels == [audioChannel])
    }

    @Test func audioInputsRemainEligibleForSideTrackRecording() {
        let inputDevice = WorkspaceInputDeviceRecord(name: "Mic", kind: .audio)

        #expect(inputDevice.kind == .audio)
    }

    @Test func unspecifiedBackgroundRemovalPolicyDoesNotRemoveBackgroundByDefault() {
        let inputDevice = WorkspaceInputDeviceRecord(name: "Camera", kind: .video)

        #expect(!inputDevice.removesBackground)
    }
}
