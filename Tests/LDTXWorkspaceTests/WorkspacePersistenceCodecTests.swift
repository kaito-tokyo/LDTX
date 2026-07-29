// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXWorkspace
import SwiftProtobuf
import Testing

struct WorkspacePersistenceCodecTests {
    @Test func encodedWorkspaceDeclaresCurrentFormatVersion() throws {
        let data = try WorkspacePersistenceCodec.encodeWorkspace(WorkspaceDefinition())
        let proto = try Ldtx_Workspace_V1_Workspace(serializedBytes: data)

        #expect(proto.formatVersion == WorkspaceMigrator.currentFormatVersion)
    }

    @Test func legacy1080p60OutputConfigurationRemainsUnspecifiedUntilRecovery() throws {
        var proto = Ldtx_Workspace_V1_Workspace()
        proto.name = "Legacy"
        proto.formatVersion = WorkspaceMigrator.currentFormatVersion
        proto.outputConfiguration.canvasWidth = 1_920
        proto.outputConfiguration.canvasHeight = 1_080
        proto.outputConfiguration.frameRate = 60

        let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())

        #expect(decoded.definition.outputConfiguration.profileID == nil)
        #expect(!decoded.definition.outputConfiguration.isSupportedOutputProfile)
    }

    @Test func supportedProfilePersistsItsStableIdentifier() throws {
        let data = try WorkspacePersistenceCodec.encodeWorkspace(WorkspaceDefinition())
        let proto = try Ldtx_Workspace_V1_Workspace(serializedBytes: data)

        #expect(proto.outputConfiguration.profileID == WorkspaceOutputProfileID.sdr1080p60.rawValue)
    }

    @Test func unsupportedLegacyOutputConfigurationRemainsProfileless() throws {
        var proto = Ldtx_Workspace_V1_Workspace()
        proto.name = "Legacy"
        proto.formatVersion = WorkspaceMigrator.currentFormatVersion
        proto.outputConfiguration.canvasWidth = 1_280
        proto.outputConfiguration.canvasHeight = 720
        proto.outputConfiguration.frameRate = 30

        let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())

        #expect(decoded.definition.outputConfiguration.profileID == nil)
        #expect(!decoded.definition.outputConfiguration.isSupportedOutputProfile)
        #expect(decoded.definition.outputConfiguration.canvasWidth == 1_280)
        #expect(decoded.definition.outputConfiguration.frameRate == 30)
    }

    @Test func decodingRejectsFutureWorkspaceFormatVersion() throws {
        var proto = Ldtx_Workspace_V1_Workspace()
        proto.formatVersion = WorkspaceMigrator.currentFormatVersion + 1

        #expect(throws: WorkspaceMigrationError.unsupportedFormatVersion(proto.formatVersion)) {
            try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())
        }
    }

    @Test func workspaceRoundTripsThroughProtobufPersistence() throws {
        let videoStep = CompositeProgramStep(
            displayName: "Camera Component",
            component: .inputCameraDevice(InputDeviceComponent(
                inputDeviceID: "Game Capture",
                sourceCropTop: 10,
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
                ),
                WorkspaceVideoComponentRecord(
                    name: "Local Clock",
                    component: .clock(ClockComponent(
                        showsSeconds: false,
                        uses24HourTime: true,
                        foregroundRed: 0.9,
                        foregroundGreen: 0.8,
                        foregroundBlue: 0.7,
                        backgroundRed: 0.1,
                        backgroundGreen: 0.2,
                        backgroundBlue: 0.3,
                        backgroundAlpha: 0.5
                    ))
                )
            ],
            outputConfiguration: WorkspaceOutputConfiguration(
                profileID: nil,
                canvasWidth: 1280,
                canvasHeight: 720,
                frameRate: 30,
                videoPTSMasterInputDeviceID: "Game Capture"
            )
        )

        let data = try WorkspacePersistenceCodec.encodeWorkspace(workspace)
        let decoded = try WorkspacePersistenceCodec.decodeWorkspace(from: data)

        #expect(decoded.definition == workspace)
        #expect(decoded.preferences == WorkspacePreferences())
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

    @Test func workspaceClockResolverPreservesResolvedLayerPlacement() throws {
        let programStep = CompositeProgramStep(
            displayName: "Clock",
            component: .clock(ClockComponent(
                destinationX: 0.2,
                destinationY: 0.3,
                destinationWidth: 0.4,
                destinationHeight: 0.5
            ))
        )
        let resource = WorkspaceVideoComponentRecord(
            name: "Clock",
            component: .clock(ClockComponent(showsDate: true))
        )
        let resolved = WorkspaceVideoComponentResolver.applying(
            [resource],
            to: CompositeProgramDefinition(steps: [programStep])
        )
        guard case .clock(let clock) = resolved.steps[0].component else {
            Issue.record("Expected Clock")
            return
        }
        #expect(clock.showsDate)
        #expect(clock.destinationX == 0.2)
        #expect(clock.destinationY == 0.3)
        #expect(clock.destinationWidth == 0.4)
        #expect(clock.destinationHeight == 0.5)
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

        #expect(decoded.definition.programs[0].composite.steps == [firstStep])
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
            outputDestination: OutputDestination(
                recordsLocally: true,
                streamsToYouTube: true,
                overridesOutputFolder: true,
                outputFolderPath: "/tmp/output"
            )
        )

        let data = try WorkspacePersistenceCodec.encodePreferences(preferences)

        #expect(try WorkspacePersistenceCodec.decodePreferences(from: data) == preferences)
    }

    @Test func applicationOutputPreferencesRoundTripOutsideWorkspacePackage() throws {
        let preferences = ApplicationOutputPreferences(defaultOutputFolderPath: "/tmp/output")

        let data = try ApplicationOutputPreferencesPersistenceCodec.encode(preferences)

        #expect(try ApplicationOutputPreferencesPersistenceCodec.decode(from: data) == preferences)
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

    @Test func decodingAcceptsVideoInputDeviceAsDirectVideoLayer() throws {
        let workspace = WorkspaceDefinition(
            programs: [
                SavedProgramDefinitionRecord(
                    name: "Gameplay",
                    canvasWidth: 1920,
                    canvasHeight: 1080,
                    frameRateNumerator: 60,
                    frameRateDenominator: 1,
                    composite: CompositeProgramDefinition(steps: [
                        CompositeProgramStep(
                            displayName: "Capture",
                            component: .inputCameraDevice(
                                InputDeviceComponent(inputDeviceID: "capture-id")
                            )
                        )
                    ])
                )
            ],
            inputDevices: [
                WorkspaceInputDeviceRecord(id: "capture-id", name: "Capture", kind: .video)
            ]
        )
        var programPreferences = ProgramPreferences()
        programPreferences.setVideoLayers(
            [VideoLayerPreference(componentName: "Capture")],
            forProgramNamed: "Gameplay"
        )
        let preferences = WorkspacePreferences(programPreferences: programPreferences)

        let snapshot = try WorkspacePersistenceCodec.decodeWorkspace(
            from: WorkspacePersistenceCodec.encodeWorkspace(workspace),
            preferences: preferences
        )

        #expect(snapshot.preferences.programPreferences.videoLayers(forProgramNamed: "Gameplay") == [
            VideoLayerPreference(componentName: "Capture")
        ])
    }

    @Test func decodingRejectsAudioInputDeviceAsDirectVideoLayer() throws {
        let workspace = WorkspaceDefinition(
            programs: [
                SavedProgramDefinitionRecord(
                    name: "Gameplay",
                    canvasWidth: 1920,
                    canvasHeight: 1080,
                    frameRateNumerator: 60,
                    frameRateDenominator: 1,
                    composite: CompositeProgramDefinition()
                )
            ],
            inputDevices: [WorkspaceInputDeviceRecord(name: "Microphone", kind: .audio)]
        )
        var programPreferences = ProgramPreferences()
        programPreferences.setVideoLayers(
            [VideoLayerPreference(componentName: "Microphone")],
            forProgramNamed: "Gameplay"
        )
        let preferences = WorkspacePreferences(programPreferences: programPreferences)

        #expect(throws: WorkspaceIntegrityError.missingReference(
            owner: "Video Layers for Gameplay",
            reference: "Microphone"
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

    @Test func persistenceOmitsWorkspaceVideoComponentDestination() throws {
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
        let component = try #require(decoded.definition.videoComponents.first?.component)
        let payload = try #require(inputDeviceComponent(in: component))

        #expect(payload.destination == InputDeviceDestination())
    }

    @Test func savingDropsLegacyWorkspaceVideoComponentDestination() throws {
        let workspace = WorkspaceDefinition(videoComponents: [
            WorkspaceVideoComponentRecord(
                name: "Camera Component",
                component: .inputCameraDevice(InputDeviceComponent(destinationX: 240))
            )
        ])

        let decoded = try WorkspacePersistenceCodec.decodeWorkspace(
            from: WorkspacePersistenceCodec.encodeWorkspace(workspace)
        )

        let component = try #require(decoded.definition.videoComponents.first?.component)
        #expect(inputDeviceComponent(in: component)?.destinationX == 0)
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

        #expect(decoded.definition.visions.first?.systemPrompt == "Legacy classification rules")
        #expect(
            decoded.definition.visions.first?.userPrompt
                == WorkspaceVisionDefinition.defaultUserPrompt
        )
    }

    @Test func currentWorkspaceDoesNotTreatMissingVideoLayersAsLegacyPlacement() throws {
        let step = CompositeProgramStep(
            displayName: "Camera Component",
            component: .inputCameraDevice(InputDeviceComponent(destinationX: 240))
        )
        let workspace = WorkspaceDefinition(programs: [
            SavedProgramDefinitionRecord(
                name: "Main",
                canvasWidth: 1920,
                canvasHeight: 1080,
                frameRateNumerator: 60,
                frameRateDenominator: 1,
                composite: CompositeProgramDefinition(steps: [step])
            )
        ])
        let snapshot = try WorkspacePersistenceCodec.decodeWorkspace(
            from: WorkspacePersistenceCodec.encodeWorkspace(workspace),
            preferences: WorkspacePreferences()
        )

        #expect(snapshot.preferences.programPreferences.videoLayers(forProgramNamed: "Main").isEmpty)
    }

    @Test func legacyWorkspaceMovesProgramPlacementAndPhysicalDevicesIntoPreferences() throws {
        let step = CompositeProgramStep(
            displayName: "Camera Component",
            component: .inputCameraDevice(InputDeviceComponent(
                inputDeviceID: "Camera",
                destinationX: 240,
                destinationY: 135,
                destinationScale: 0.5
            ))
        )
        let workspace = WorkspaceDefinition(
            programs: [
                SavedProgramDefinitionRecord(
                    name: "Main",
                    canvasWidth: 1920,
                    canvasHeight: 1080,
                    frameRateNumerator: 60,
                    frameRateDenominator: 1,
                    composite: CompositeProgramDefinition(steps: [step])
                )
            ],
            inputDevices: [WorkspaceInputDeviceRecord(name: "Camera", kind: .video)],
            videoComponents: [
                WorkspaceVideoComponentRecord(
                    name: "Camera Component",
                    component: .inputCameraDevice(InputDeviceComponent(inputDeviceID: "Camera"))
                )
            ]
        )
        var proto = try Ldtx_Workspace_V1_Workspace(
            serializedBytes: WorkspacePersistenceCodec.encodeWorkspace(workspace)
        )
        proto.formatVersion = 0
        proto.inputDevices[0].physicalDeviceID = "physical-camera"
        var destination = Ldtx_Program_V1_Destination()
        destination.x = 240
        destination.y = 135
        destination.scale = 0.5
        proto.programs[0].program.components[0].inputDevice.destination = destination

        let snapshot = try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())

        #expect(snapshot.preferences.physicalDeviceIDsByInputDeviceID == [
            "Camera": "physical-camera"
        ])
        #expect(snapshot.preferences.programPreferences.videoLayers(forProgramNamed: "Main") == [
            VideoLayerPreference(
                componentName: "Camera Component",
                destinationX: 240,
                destinationY: 135,
                destinationScale: 0.5
            )
        ])
        let migratedStep = try #require(snapshot.definition.programs.first?.composite.steps.first)
        #expect(inputDeviceComponent(in: migratedStep.component)?.destination == InputDeviceDestination())
    }

    @Test func legacyWorkspacePromotesInlineProgramComponentsBeforeCreatingVideoLayers() throws {
        let inlineStep = CompositeProgramStep(
            displayName: "Background",
            component: .fillSolidColor(FillSolidColorComponent(red: 0.1, green: 0.2, blue: 0.3))
        )
        let workspace = WorkspaceDefinition(
            programs: [
                SavedProgramDefinitionRecord(
                    name: "Main",
                    canvasWidth: 1920,
                    canvasHeight: 1080,
                    frameRateNumerator: 60,
                    frameRateDenominator: 1,
                    composite: CompositeProgramDefinition(steps: [inlineStep])
                )
            ]
        )
        var proto = try Ldtx_Workspace_V1_Workspace(
            serializedBytes: WorkspacePersistenceCodec.encodeWorkspace(workspace)
        )
        proto.formatVersion = 0

        let snapshot = try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())

        #expect(snapshot.definition.videoComponents == [
            WorkspaceVideoComponentRecord(
                name: "Background",
                component: .fillSolidColor(FillSolidColorComponent(red: 0.1, green: 0.2, blue: 0.3))
            )
        ])
        #expect(snapshot.preferences.programPreferences.videoLayers(forProgramNamed: "Main") == [
            VideoLayerPreference(componentName: "Background")
        ])
    }

    @Test func legacyWorkspacePromotionAvoidsOtherWorkspaceResourceNames() throws {
        let inlineStep = CompositeProgramStep(
            displayName: "Camera",
            component: .fillSolidColor(FillSolidColorComponent(red: 0.1, green: 0.2, blue: 0.3))
        )
        let workspace = WorkspaceDefinition(
            programs: [
                SavedProgramDefinitionRecord(
                    name: "Main",
                    canvasWidth: 1920,
                    canvasHeight: 1080,
                    frameRateNumerator: 60,
                    frameRateDenominator: 1,
                    composite: CompositeProgramDefinition(steps: [inlineStep])
                )
            ],
            inputDevices: [WorkspaceInputDeviceRecord(name: "Camera", kind: .video)]
        )
        var proto = try Ldtx_Workspace_V1_Workspace(
            serializedBytes: WorkspacePersistenceCodec.encodeWorkspace(workspace)
        )
        proto.formatVersion = 0

        let snapshot = try WorkspacePersistenceCodec.decodeWorkspace(from: proto.serializedData())

        #expect(snapshot.definition.videoComponents.map(\.name) == ["Camera 2"])
        #expect(snapshot.preferences.programPreferences.videoLayers(forProgramNamed: "Main") == [
            VideoLayerPreference(componentName: "Camera 2")
        ])
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

        #expect(decoded.definition == workspace)
        #expect(decoded.preferences == WorkspacePreferences())
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
