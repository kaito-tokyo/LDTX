// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#if DEBUG
import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import LDTXYouTube

@MainActor
enum LDTXAppUIPreviewFixtures {
    static let workspaceInputDevices: [WorkspaceInputDeviceRecord] = [
        WorkspaceInputDeviceRecord(
            id: "workspace-video-1",
            name: "Desk Camera",
            kind: .video,
            physicalDeviceID: "physical-camera-1",
            backgroundRemovalPolicy: .enabled
        ),
        WorkspaceInputDeviceRecord(
            id: "workspace-audio-1",
            name: "Desk Mic",
            kind: .audio,
            physicalDeviceID: "physical-audio-1"
        ),
    ]

    static let cameras: [InputPhysicalDeviceOption] = [
        InputPhysicalDeviceOption(id: "physical-camera-1", name: "Studio Display Camera", isExternal: false),
        InputPhysicalDeviceOption(id: "physical-camera-2", name: "HDMI Capture Camera", isExternal: true),
    ]

    static let audioDevices: [InputPhysicalDeviceOption] = [
        InputPhysicalDeviceOption(id: "physical-audio-1", name: "USB Podcast Mic", isExternal: true),
        InputPhysicalDeviceOption(id: "physical-audio-2", name: "Built-in Audio", isExternal: false),
    ]

    static let compositeProgramDefinition: CompositeProgramDefinition = {
        let primaryCameraStep = CompositeProgramStep(
            component: .inputCameraDevice(
                InputDeviceComponent(
                    inputDeviceID: "workspace-video-1",
                    sourceCropTop: 4,
                    sourceCropRight: 2,
                    destinationX: 96,
                    destinationY: 72,
                    destinationScale: 1.08
                )
            )
        )
        let primaryAudioChannel = ProgramAudioChannel(
            component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "workspace-audio-1"))
        )
        var composite = CompositeProgramDefinition(
            steps: [
                primaryCameraStep,
                CompositeProgramStep(
                    component: .fillLinearGradient(FillLinearGradientComponent())
                ),
                CompositeProgramStep(
                    component: .fillSolidColor(
                        FillSolidColorComponent(
                            red: 0.95,
                            green: 0.18,
                            blue: 0.26,
                            alpha: 0.9,
                            clip: FillClip(top: 64, right: 48, bottom: 832, left: 1360)
                        )
                    )
                ),
            ],
            audioChannels: [
                primaryAudioChannel,
                ProgramAudioChannel(
                    component: .silentAudio
                ),
            ]
        )
        composite.programVideoPTSInputKey = composite.inputCameraDeviceMappingKey(for: primaryCameraStep)
        composite.programAudioPTSInputKey = composite.audioChannelKey(for: primaryAudioChannel)
        return composite
    }()

    static let workspaceAudioChannels = compositeProgramDefinition.audioChannels

    static let selectedProgramDefinitionRecord = SavedProgramDefinitionRecord(
        name: "Demo Program",
        canvasWidth: programWorldCanvasSize.width,
        canvasHeight: programWorldCanvasSize.height,
        frameRateNumerator: 60,
        frameRateDenominator: 1,
        composite: compositeProgramDefinition,
        inputDevices: workspaceInputDevices
    )

    static let programRecords: [SavedProgramDefinitionRecord] = [
        selectedProgramDefinitionRecord,
        SavedProgramDefinitionRecord(
            name: "Backup Program",
            canvasWidth: programWorldCanvasSize.width,
            canvasHeight: programWorldCanvasSize.height,
            frameRateNumerator: 30,
            frameRateDenominator: 1,
            composite: CompositeProgramDefinition(
                steps: [
                    CompositeProgramStep(component: .fillConicGradient(FillConicGradientComponent()))
                ]
            ),
            inputDevices: []
        ),
    ]

    static let programArguments: ProgramArguments = {
        var arguments = ProgramArguments()
        let firstChannel = workspaceAudioChannels[0]
        let secondChannel = workspaceAudioChannels[1]
        arguments.audioChannelGainsByName[workspaceAudioChannels.audioChannelKey(for: firstChannel)] = 1.0
        arguments.audioChannelGainsByName[workspaceAudioChannels.audioChannelKey(for: secondChannel)] =
            ProgramArguments.linearAudioChannelGain(fromDecibels: -6)
        return arguments
    }()

    static let selectedSidebarItem: WorkspaceSidebarItem? = .streamSettings
    static let selectedProgramDefinitionName: String? = "Demo Program"

    static let existingBroadcasts: [YouTubeLiveBroadcast] = [
        YouTubeLiveBroadcast(
            id: "broadcast-1",
            snippet: YouTubeLiveBroadcast.Snippet(
                title: "Weekly Preview Stream",
                description: "Preview broadcast used for the UI canvas.",
                scheduledStartTime: "2026-07-06T13:00:00Z"
            ),
            status: YouTubeLiveBroadcast.Status(
                lifeCycleStatus: "upcoming",
                privacyStatus: .unlisted
            ),
            contentDetails: YouTubeLiveBroadcast.ContentDetails(
                boundStreamId: "stream-1",
                latencyPreference: .low
            )
        )
    ]

    static let inputCameraDeviceMappings: [String: String] = [:]
    static let streamTitle = "Weekly Preview Stream"
    static let streamDescription = "Preview configuration for the workspace UI."
    static let oauthClientStatus = "OAuth client loaded"
    static let authorizationStatus = "Authorized for @preview"
    static let streamStatus = "Ready to stream"
    static let captureStatus = "2 devices connected"
    static let localOutputStatus = "Recording to ~/Movies/LDTX"

    static func makeWorkspaceCaptureSessionCoordinator() -> WorkspaceCaptureSessionCoordinator {
        WorkspaceCaptureSessionCoordinator()
    }

    static func makeActiveProgramRuntime(
        coordinator: WorkspaceCaptureSessionCoordinator
    ) -> ActiveProgramRuntime {
        ActiveProgramRuntime(captureSessionCoordinator: coordinator)
    }

    static func makeAudioPeakMeter() -> ProgramAudioPeakMeter {
        ProgramAudioPeakMeter()
    }

    static func makeOutputCanvasModel() -> OutputCanvasModel {
        OutputCanvasModel(
            canvasSize: OutputCanvasModel.CanvasSize(
                width: selectedProgramDefinitionRecord.canvasWidth,
                height: selectedProgramDefinitionRecord.canvasHeight
            ),
            programDefinitionFrameRate: 60,
            programVideoPTSInputKey: compositeProgramDefinition.programVideoPTSInputKey
        )
    }

    static func makeOutputDestinationModel() -> OutputDestinationModel {
        OutputDestinationModel(
            selectedResolution: .p1080,
            selectedFrameRate: .fps60,
            selectedExistingBroadcastID: "broadcast-1",
            selectedCaptureOutputMode: .youtubeAndRecord,
            streamTitle: streamTitle,
            streamDescription: streamDescription,
            usesTemporaryStream: true
        )
    }

    static func makeActiveProgramSnapshot(
        outputCanvas: OutputCanvasModel,
        compositeProgramDefinition: CompositeProgramDefinition,
        workspaceInputDevices: [WorkspaceInputDeviceRecord] = workspaceInputDevices,
        workspaceAudioChannels: [ProgramAudioChannel] = workspaceAudioChannels,
        inputCameraDeviceMappings: [String: String] = inputCameraDeviceMappings
    ) -> ProgramPreviewSnapshot {
        let composite = outputCanvas.applying(to: compositeProgramDefinition)
        let cameraIDsByInputKey = mappedInputCameraDeviceIDs(
            for: .composite,
            composite: composite,
            workspaceInputDevices: workspaceInputDevices,
            inputCameraDeviceMappings: inputCameraDeviceMappings
        )
        return ProgramPreviewSnapshot(
            definition: .composite,
            composite: composite,
            audioChannels: workspaceAudioChannels,
            canvasWidth: outputCanvas.canvasSize.width,
            canvasHeight: outputCanvas.canvasSize.height,
            outputWidth: outputCanvas.canvasSize.width,
            outputHeight: outputCanvas.canvasSize.height,
            frameRate: max(outputCanvas.programDefinitionFrameRate, 1),
            timeSeconds: Float(ProcessInfo.processInfo.systemUptime),
            programVideoPTSInputKey: programVideoPTSInputKey(
                for: .composite,
                composite: composite,
                cameraIDsByInputKey: cameraIDsByInputKey
            ),
            programAudioDriverKey: programAudioDriverKey(
                for: .composite,
                composite: composite,
                audioChannels: workspaceAudioChannels
            ),
            cameraIDsByInputKey: cameraIDsByInputKey,
            cameraInputColorOverrides: inputCameraColorRangeOverrides(
                for: .composite,
                composite: composite,
                workspaceInputDevices: workspaceInputDevices
            ),
            backgroundRemovalInputKeys: backgroundRemovalInputCameraDeviceKeys(
                for: .composite,
                composite: composite,
                workspaceInputDevices: workspaceInputDevices
            )
        )
    }
}
#endif
