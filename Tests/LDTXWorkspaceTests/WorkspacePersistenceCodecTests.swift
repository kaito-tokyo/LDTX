// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import SwiftProtobuf
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
            inputDevices: [
                WorkspaceInputDeviceRecord(
                    id: "workspace-camera",
                    name: "Game Capture",
                    kind: .video,
                    backgroundRemovalPolicy: .enabled,
                    captureWidthOverride: 1280,
                    captureHeightOverride: 720,
                    captureFrameRateOverride: 30
                ),
                WorkspaceInputDeviceRecord(
                    id: "workspace-game-audio",
                    name: "Game Audio",
                    kind: .audio,
                ),
                WorkspaceInputDeviceRecord(
                    id: "workspace-mic",
                    name: "Mic",
                    kind: .audio,
                    sideTrackRecordingPolicy: .disabled
                )
            ],
            audioChannels: [audioChannel],
            visions: [
                WorkspaceVisionDefinition(
                    id: "vision-1",
                    name: "Scene Analyzer",
                    source: .inputDevice(id: "workspace-camera"),
                    model: WorkspaceVisionModel(repositoryID: "mlx-community/Qwen3-VL-2B-Instruct-4bit"),
                    systemPrompt: "Return a concise scene description.",
                    userPrompt: "Describe this frame.",
                    updateIntervalSeconds: 2,
                    stopsAtNewline: true,
                    postActionAutomationID: "automation-2"
                )
            ],
            automations: [
                WorkspaceAutomationDefinition(
                    id: "automation-1",
                    name: "Analyze Periodically",
                    trigger: .interval(seconds: 5),
                    actions: [
                        .analyzeVision(id: "action-1", visionID: "vision-1"),
                        .selectInputDevice(id: "action-2", inputDeviceID: "workspace-camera")
                    ]
                ),
                WorkspaceAutomationDefinition(
                    id: "automation-2",
                    name: "React to Vision",
                    isEnabled: false,
                    trigger: .manual
                )
            ]
        )

        let data = try WorkspacePersistenceCodec.encodeWorkspace(workspace)
        let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: data)

        XCTAssertEqual(decoded, workspace)
    }

    func testWorkspacePreferencesRoundTripSeparatelyFromDefinition() throws {
        let preferences = WorkspacePreferences(
            programPreferences: [
                SavedProgramPreferencesRecord(
                    name: "Switch 2",
                    preferences: ProgramPreferences(audioChannelGainsByName: ["mic": 0.5])
                )
            ],
            physicalDeviceIDsByInputDeviceID: ["camera": "physical-camera"],
            inputCameraDeviceMappings: ["camera-step": "physical-camera"],
            inputAudioDeviceMappings: ["audio-channel": "physical-audio"],
            inputAudioMonitorChannelKeys: ["audio-channel"],
            selectedProgramName: "Switch 2",
            output: WorkspaceOutputPreferences(
                captureOutputMode: "record",
                streamTitle: "Test",
                localOutputBaseDirectoryPath: "/tmp/output"
            )
        )

        let data = try WorkspacePersistenceCodec.encodePreferences(preferences)

        XCTAssertEqual(try WorkspacePersistenceCodec.decodePreferences(from: data), preferences)
    }

    func testEncodingRejectsDuplicateResourceNamesAcrossKinds() {
        let workspace = WorkspaceDefinition(
            inputDevices: [WorkspaceInputDeviceRecord(name: "Shared", kind: .video)],
            visions: [WorkspaceVisionDefinition(name: "Shared")]
        )

        XCTAssertThrowsError(try WorkspacePersistenceCodec.encodeWorkspace(workspace)) { error in
            XCTAssertEqual(error as? WorkspaceResourceNameValidationError, .duplicateName("Shared"))
        }
    }

    func testDecodingRejectsDuplicateResourceNamesAcrossKinds() throws {
        var inputDevice = Ldtx_Workspace_V1_InputDeviceRecord()
        inputDevice.id = "input"
        inputDevice.name = "Shared"
        var vision = Ldtx_Workspace_V1_VisionRecord()
        vision.id = "vision"
        vision.name = "Shared"
        var proto = Ldtx_Workspace_V1_Workspace()
        proto.inputDevices = [inputDevice]
        proto.visions = [vision]

        XCTAssertThrowsError(try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())) { error in
            XCTAssertEqual(error as? WorkspaceResourceNameValidationError, .duplicateName("Shared"))
        }
    }

    func testLegacyVisionPromptMigratesToSystemPrompt() throws {
        var vision = Ldtx_Workspace_V1_VisionRecord()
        vision.id = "legacy-vision"
        vision.name = "Legacy Vision"
        vision.currentProgramOutput = true
        vision.prompt = "Legacy classification rules"

        var proto = Ldtx_Workspace_V1_Workspace()
        proto.id = "legacy-workspace"
        proto.name = "Legacy Workspace"
        proto.visions = [vision]

        let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())

        XCTAssertEqual(decoded.visions.first?.systemPrompt, "Legacy classification rules")
        XCTAssertEqual(decoded.visions.first?.userPrompt, WorkspaceVisionDefinition.defaultUserPrompt)
    }

    func testLegacyVisionResultTriggerMigratesToPostAction() throws {
        var vision = Ldtx_Workspace_V1_VisionRecord()
        vision.id = "vision"
        var trigger = Ldtx_Workspace_V1_AutomationTrigger()
        trigger.visionResultChangedID = "vision"
        var automation = Ldtx_Workspace_V1_AutomationRecord()
        automation.id = "automation"
        automation.isEnabled = true
        automation.trigger = trigger
        var proto = Ldtx_Workspace_V1_Workspace()
        proto.visions = [vision]
        proto.automations = [automation]

        let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())

        XCTAssertEqual(decoded.visions[0].postActionAutomationID, "automation")
        XCTAssertEqual(decoded.automations[0].trigger, .manual)
    }

    func testConflictingLegacyVisionResultTriggersBecomeManual() throws {
        var vision = Ldtx_Workspace_V1_VisionRecord()
        vision.id = "vision"
        var trigger = Ldtx_Workspace_V1_AutomationTrigger()
        trigger.visionResultChangedID = "vision"
        var first = Ldtx_Workspace_V1_AutomationRecord()
        first.id = "first"
        first.name = "First Automation"
        first.isEnabled = true
        first.trigger = trigger
        var second = Ldtx_Workspace_V1_AutomationRecord()
        second.id = "second"
        second.name = "Second Automation"
        second.isEnabled = true
        second.trigger = trigger
        var proto = Ldtx_Workspace_V1_Workspace()
        proto.visions = [vision]
        proto.automations = [first, second]

        let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())

        XCTAssertNil(decoded.visions[0].postActionAutomationID)
        XCTAssertTrue(decoded.automations.allSatisfy { $0.trigger == .manual })
    }

    func testWorkspaceJSONRoundTripsThroughProtobufPersistence() throws {
        let videoStep = CompositeProgramStep(
            component: .inputCameraDevice(InputDeviceComponent(inputDeviceID: "workspace-camera"))
        )
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
                    composite: CompositeProgramDefinition(steps: [videoStep])
                )
            ],
            inputDevices: [
                WorkspaceInputDeviceRecord(
                    id: "workspace-camera",
                    name: "Camera",
                    kind: .video,
                    captureWidthOverride: 1280,
                    captureHeightOverride: 720,
                    captureFrameRateOverride: 30
                ),
                WorkspaceInputDeviceRecord(
                    id: "workspace-commentary",
                    name: "Commentary",
                    kind: .audio,
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
