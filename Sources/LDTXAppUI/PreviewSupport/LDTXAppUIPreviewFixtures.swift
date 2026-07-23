// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#if DEBUG
import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace

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
        let audioChannel = ProgramAudioChannel(
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
                audioChannel,
                ProgramAudioChannel(
                    component: .silentAudio
                ),
            ]
        )
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

    static let programPreferences: ProgramPreferences = {
        var preferences = ProgramPreferences()
        let firstChannel = workspaceAudioChannels[0]
        let secondChannel = workspaceAudioChannels[1]
        preferences.audioChannelGainsByName[workspaceAudioChannels.audioChannelKey(for: firstChannel)] = 1.0
        preferences.audioChannelGainsByName[workspaceAudioChannels.audioChannelKey(for: secondChannel)] =
            ProgramPreferences.linearAudioChannelGain(fromDecibels: -6)
        return preferences
    }()

    static let selectedSidebarItem: WorkspaceSidebarItem? = .streamSettings
    static let selectedProgramDefinitionName: String? = "Demo Program"

    static let existingBroadcasts: [LiveBroadcastSummary] = [
        LiveBroadcastSummary(
            id: "broadcast-1",
            title: "Weekly Preview Stream",
            statusLabel: "Upcoming"
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

    static func makeProgramRuntime(
        coordinator: WorkspaceCaptureSessionCoordinator
    ) -> ProgramRuntime {
        ProgramRuntime(captureSessionCoordinator: coordinator)
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
            programDefinitionFrameRate: 60
        )
    }

    static func makeAppOutputSettings() -> AppOutputSettings {
        AppOutputSettings(
            recording: .init(isEnabled: true),
            youtube: .init(
                isEnabled: true,
                existingBroadcastID: "broadcast-1",
                streamTitle: streamTitle,
                streamDescription: streamDescription
            )
        )
    }

    static func makeAppPreviewSettings() -> AppPreviewSettings {
        AppPreviewSettings()
    }

}
#endif
