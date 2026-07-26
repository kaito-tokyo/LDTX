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
            displayName: "Camera Component",
            component: .inputCameraDevice(InputDeviceComponent(
                inputDeviceID: "Game Capture",
                sourceCropTop: 10,
                destinationScale: 0.85,
                removesBackground: true
            ))
        )
        let audioChannel = ProgramAudioChannel(
            component: .inputAudioDevice(InputAudioDeviceComponent())
        )
        let composite = CompositeProgramDefinition(
            steps: [videoStep],
            audioChannels: [audioChannel]
        )

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
                    stopsAtNewline: true
                )
            ],
            videoComponents: [
                WorkspaceVideoComponentRecord(
                    name: "Camera Component",
                    inputDeviceID: "Game Capture",
                    sourceCropTop: 10,
                    removesBackground: true
                ),
                WorkspaceVideoComponentRecord(
                    name: "Background",
                    component: .fillSolidColor(FillSolidColorComponent(red: 0.1, green: 0.2, blue: 0.3))
                )
            ],
            outputConfiguration: WorkspaceOutputConfiguration(
                canvasWidth: 1280,
                canvasHeight: 720,
                frameRate: 30,
                videoPTSMasterInputDeviceID: "Game Capture"
            )
        )

        let data = try WorkspacePersistenceCodec.encodeWorkspace(workspace)
        let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: data)

        #expect(decoded == workspace)
    }

    @Test func backgroundRemovalCanBeDisabledExplicitly() throws {
        var workspace = WorkspaceDefinition(
            videoComponents: [WorkspaceVideoComponentRecord(
                name: "Portrait",
                component: .inputCameraDevice(InputDeviceComponent(removesBackground: true))
            )]
        )

        #expect(workspace.videoComponents[0].removesBackground)

        workspace.videoComponents[0].removesBackground = false
        #expect(!workspace.videoComponents[0].removesBackground)
    }

    @Test func workspaceVideoComponentResolverPreservesOnlyProgramDestination() throws {
        let programStep = CompositeProgramStep(
            displayName: "Portrait",
            component: .inputCameraDevice(InputDeviceComponent(
                inputDeviceID: "Old Camera",
                sourceCropTop: 1,
                destinationX: 120,
                destinationY: 80,
                destinationScale: 0.5
            ))
        )
        let resource = WorkspaceVideoComponentRecord(
            name: "Portrait",
            inputDeviceID: "Current Camera",
            sourceCropTop: 25,
            removesBackground: true
        )

        let resolved = WorkspaceVideoComponentResolver.applying(
            [resource],
            to: CompositeProgramDefinition(steps: [programStep])
        )
        let payload = try #require(inputDeviceComponent(in: resolved.steps[0].component))

        #expect(payload.inputDeviceID == "Current Camera")
        #expect(payload.sourceCropTop == 25)
        #expect(payload.removesBackground)
        #expect(payload.destinationX == 120)
        #expect(payload.destinationY == 80)
        #expect(payload.destinationScale == 0.5)
    }

    @Test func videoComponentResolverUsesTheFirstComponentForDuplicateNames() throws {
        let first = WorkspaceVideoComponentRecord(
            name: "Camera",
            inputDeviceID: "First Camera",
            sourceCropTop: 10
        )
        let duplicate = WorkspaceVideoComponentRecord(
            name: "Camera",
            inputDeviceID: "Second Camera",
            sourceCropTop: 25
        )
        let composite = CompositeProgramDefinition(steps: [
            CompositeProgramStep(
                displayName: "Camera",
                component: .inputCameraDevice(InputDeviceComponent())
            )
        ])

        let resolved = WorkspaceVideoComponentResolver.applying([first, duplicate], to: composite)
        let payload = try #require(inputDeviceComponent(in: resolved.steps[0].component))

        #expect(payload.inputDeviceID == "First Camera")
        #expect(payload.sourceCropTop == 10)
    }

    @Test func decodingDiscardsDuplicateProgramStepsAfterTheFirst() throws {
        let firstStep = CompositeProgramStep(
            displayName: "Camera",
            component: .inputCameraDevice(InputDeviceComponent(sourceCropTop: 10))
        )
        let duplicateStep = CompositeProgramStep(
            displayName: "Camera",
            component: .inputCameraDevice(InputDeviceComponent(sourceCropTop: 25))
        )
        let workspace = WorkspaceDefinition(programs: [
            SavedProgramDefinitionRecord(
                name: "Main",
                canvasWidth: 1920,
                canvasHeight: 1080,
                frameRateNumerator: 60,
                frameRateDenominator: 1,
                composite: CompositeProgramDefinition(steps: [firstStep, duplicateStep])
            )
        ])

        let decoded = try WorkspacePersistenceCodec.decodeWorkspace(
            from: WorkspacePersistenceCodec.encodeWorkspace(workspace)
        )

        #expect(decoded.programs[0].composite.steps == [firstStep])
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
            selectedProgramName: "Switch 2"
        )

        let data = try WorkspacePersistenceCodec.encodePreferences(preferences)

        #expect(try WorkspacePersistenceCodec.decodePreferences(from: data) == preferences)
    }

    @Test func appOutputSettingsRoundTripOutsideWorkspacePackage() throws {
        let settings = AppOutputSettings(
            recording: .init(
                isEnabled: true,
                baseDirectoryURL: URL(fileURLWithPath: "/tmp/output", isDirectory: true)
            ),
            youtube: .init(
                isEnabled: false,
                existingBroadcastID: "broadcast-1",
                streamTitle: "Test",
                streamDescription: "Description"
            )
        )

        let data = try AppOutputSettingsPersistenceCodec.encode(settings)

        #expect(try AppOutputSettingsPersistenceCodec.decode(from: data) == settings)
    }

    @Test func appPreviewSettingsRoundTripOutsideWorkspacePackage() throws {
        let settings = AppPreviewSettings(prefersColor: true)

        let data = try AppPreviewSettingsPersistenceCodec.encode(settings)

        #expect(try AppPreviewSettingsPersistenceCodec.decode(from: data) == settings)
    }

    @Test func savingPreservesDuplicateResourceNames() throws {
        let workspace = WorkspaceDefinition(
            inputDevices: [WorkspaceInputDeviceRecord(name: "Shared", kind: .video)],
            visions: [WorkspaceVisionDefinition(name: "Shared")]
        )

        #expect(try WorkspacePersistenceCodec.encodeWorkspace(workspace).isEmpty == false)
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

    @Test func decodingRejectsDuplicateInputDeviceNames() throws {
        var first = Ldtx_Workspace_V1_InputDeviceRecord()
        first.name = "Duplicate Camera"
        var second = Ldtx_Workspace_V1_InputDeviceRecord()
        second.name = "Duplicate Camera"
        var proto = Ldtx_Workspace_V1_Workspace()
        proto.inputDevices = [first, second]

        #expect(throws: WorkspaceResourceNameValidationError.duplicateName("Duplicate Camera")) {
            try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())
        }
    }

    @Test func decodingRejectsDuplicateProgramNames() throws {
        let program = SavedProgramDefinitionRecord(
            name: "Gameplay",
            canvasWidth: 1920,
            canvasHeight: 1080,
            frameRateNumerator: 60,
            frameRateDenominator: 1,
            composite: CompositeProgramDefinition()
        )
        let workspace = WorkspaceDefinition(programs: [program, program])

        #expect(throws: WorkspaceIntegrityError.duplicateProgramName("Gameplay")) {
            try WorkspacePersistenceCodec.decodeWorkspace(
                from: WorkspacePersistenceCodec.encodeWorkspace(workspace)
            )
        }
    }

    @Test func decodingWorkspaceWithPreferencesRejectsMissingSelectedProgram() throws {
        let workspace = WorkspaceDefinition(programs: [
            SavedProgramDefinitionRecord(
                name: "Gameplay",
                canvasWidth: 1920,
                canvasHeight: 1080,
                frameRateNumerator: 60,
                frameRateDenominator: 1,
                composite: CompositeProgramDefinition()
            )
        ])
        let preferences = WorkspacePreferences(selectedProgramName: "Missing Program")

        #expect(throws: WorkspaceIntegrityError.missingReference(
            owner: "Workspace Preferences",
            reference: "Missing Program"
        )) {
            try WorkspacePersistenceCodec.decodeWorkspace(
                from: WorkspacePersistenceCodec.encodeWorkspace(workspace),
                preferences: preferences
            )
        }
    }

    @Test func decodingRejectsMissingWorkspaceVideoPTSMaster() throws {
        let workspace = WorkspaceDefinition(
            outputConfiguration: WorkspaceOutputConfiguration(
                videoPTSMasterInputDeviceID: "Missing Camera"
            )
        )

        #expect(throws: WorkspaceIntegrityError.missingReference(
            owner: "Workspace Output Configuration",
            reference: "Missing Camera"
        )) {
            try WorkspacePersistenceCodec.decodeWorkspace(
                from: WorkspacePersistenceCodec.encodeWorkspace(workspace)
            )
        }
    }

    @Test func decodingRejectsVideoComponentWithMissingInputDevice() throws {
        var component = Ldtx_Workspace_V1_VideoComponentRecord()
        component.name = "Camera"
        component.component = ProgramPersistenceCodec.encodeProgramComponent(
            .inputCameraDevice(InputDeviceComponent(inputDeviceID: "Missing Camera"))
        )
        var proto = Ldtx_Workspace_V1_Workspace()
        proto.videoComponents = [component]

        #expect(throws: WorkspaceIntegrityError.missingReference(
            owner: "Video Component Camera",
            reference: "Missing Camera"
        )) {
            try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())
        }
    }

    @Test func persistencePreservesWorkspaceVideoComponentDestination() throws {
        let workspace = WorkspaceDefinition(videoComponents: [
            WorkspaceVideoComponentRecord(
                name: "Camera Component",
                component: .inputCameraDevice(InputDeviceComponent(
                    destinationX: 120,
                    destinationY: 80,
                    destinationScale: 0.5
                ))
            )
        ])

        let decoded = try WorkspacePersistenceCodec.decodeWorkspace(
            from: WorkspacePersistenceCodec.encodeWorkspace(workspace)
        )
        let component = try #require(decoded.videoComponents.first?.component)
        let payload = try #require(inputDeviceComponent(in: component))

        #expect(payload.destinationX == 120)
        #expect(payload.destinationY == 80)
        #expect(payload.destinationScale == 0.5)
    }

    @Test func savingDoesNotRewriteWorkspaceVideoComponentDestination() throws {
        let workspace = WorkspaceDefinition(videoComponents: [
            WorkspaceVideoComponentRecord(
                name: "Camera Component",
                component: .inputCameraDevice(InputDeviceComponent(destinationX: 240))
            )
        ])

        let decoded = try WorkspacePersistenceCodec.decodeWorkspace(
            from: WorkspacePersistenceCodec.encodeWorkspace(workspace)
        )

        let component = try #require(decoded.videoComponents.first?.component)
        #expect(inputDeviceComponent(in: component)?.destinationX == 240)
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
            component: .inputCameraDevice(InputDeviceComponent(inputDeviceID: "Camera"))
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
            ],
            videoComponents: [
                WorkspaceVideoComponentRecord(
                    name: videoStep.name,
                    inputDeviceID: "Camera"
                )
            ]
        )

        let data = try WorkspacePersistenceCodec.encodeWorkspaceJSON(workspace)
        let decoded = try WorkspacePersistenceCodec.decodeWorkspaceJSON(from: data)

        #expect(decoded == workspace)
    }

    @Test func audioInputsRemainEligibleForSideTrackRecording() {
        let inputDevice = WorkspaceInputDeviceRecord(name: "Mic", kind: .audio)

        #expect(inputDevice.kind == .audio)
    }

    @Test func unspecifiedBackgroundRemovalPolicyDoesNotRemoveBackgroundByDefault() {
        let inputDevice = WorkspaceInputDeviceRecord(name: "Camera", kind: .video)

        #expect(!inputDevice.removesBackground)
    }

    private func inputDeviceComponent(in component: ProgramComponent) -> InputDeviceComponent? {
        guard case .inputCameraDevice(let payload) = component else { return nil }
        return payload
    }
}
