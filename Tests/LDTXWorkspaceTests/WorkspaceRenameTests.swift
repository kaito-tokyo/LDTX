// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import LDTXWorkspace
import Testing

struct WorkspaceRenameTests {
    @Test
    func inputDeviceRenameUpdatesEveryWorkspaceReferenceAtomically() throws {
        let videoStep = CompositeProgramStep(
            component: .inputCameraDevice(InputDeviceComponent(inputDeviceID: "Camera"))
        )
        let audioChannel = ProgramAudioChannel(
            component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "Camera"))
        )
        let program = SavedProgramDefinitionRecord(
            name: "Program",
            canvasWidth: 1920,
            canvasHeight: 1080,
            frameRateNumerator: 60,
            frameRateDenominator: 1,
            composite: CompositeProgramDefinition(steps: [videoStep], audioChannels: [audioChannel]),
            inputDevices: [ProgramInputDeviceRecord(name: "Camera", kind: .video)]
        )
        var workspace = WorkspaceDefinition(
            programs: [program],
            inputDevices: [WorkspaceInputDeviceRecord(name: "Camera", kind: .video)],
            audioChannels: [audioChannel],
            visions: [WorkspaceVisionDefinition(source: .inputDevice(name: "Camera"))],
            videoComponents: [WorkspaceVideoComponentRecord(
                name: "Camera Component",
                inputDeviceID: "Camera"
            )],
            outputConfiguration: WorkspaceOutputConfiguration(
                videoPTSMasterInputDeviceID: "Camera"
            )
        )
        var preferences = WorkspacePreferences(
            programPreferences: ProgramPreferences(
                videoMutedByInputDeviceName: ["Camera": true]
            ),
            physicalDeviceIDsByInputDeviceID: ["Camera": "physical-camera"]
        )

        try workspace.renameInputDevice(from: "Camera", to: "Front Camera", preferences: &preferences)

        #expect(workspace.inputDevices[0].name == "Front Camera")
        #expect(workspace.programs[0].inputDevices[0].name == "Front Camera")
        if case .inputCameraDevice(let component) = workspace.programs[0].composite.steps[0].component {
            #expect(component.inputDeviceID == "Front Camera")
        } else {
            Issue.record("Expected camera input component")
        }
        if case .inputAudioDevice(let component) = workspace.audioChannels[0].component {
            #expect(component.inputDeviceID == "Front Camera")
        } else {
            Issue.record("Expected audio input component")
        }
        #expect(workspace.visions[0].source == .inputDevice(name: "Front Camera"))
        #expect(workspace.videoComponents[0].inputDeviceID == "Front Camera")
        #expect(preferences.programPreferences.isVideoMuted(inputDeviceName: "Front Camera"))
        #expect(preferences.physicalDeviceIDsByInputDeviceID == ["Front Camera": "physical-camera"])
    }

    @Test
    func inputDeviceRenameUpdatesVideoPTSMaster() throws {
        var workspace = WorkspaceDefinition(
            inputDevices: [WorkspaceInputDeviceRecord(name: "Camera", kind: .video)],
            outputConfiguration: WorkspaceOutputConfiguration(
                videoPTSMasterInputDeviceID: "Camera"
            )
        )
        var preferences = WorkspacePreferences()

        try workspace.renameInputDevice(from: "Camera", to: "Main Camera", preferences: &preferences)

        #expect(workspace.outputConfiguration.videoPTSMasterInputDeviceID == "Main Camera")
    }

    @Test
    func inputDeviceDeletionClearsEveryWorkspaceReferenceAtomically() {
        let cameraStep = CompositeProgramStep(
            displayName: "Camera Component",
            component: .inputCameraDevice(InputDeviceComponent(inputDeviceID: "Camera"))
        )
        let audioChannel = ProgramAudioChannel(
            component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "Camera"))
        )
        var workspace = WorkspaceDefinition(
            programs: [SavedProgramDefinitionRecord(
                name: "Program",
                canvasWidth: 1920,
                canvasHeight: 1080,
                frameRateNumerator: 60,
                frameRateDenominator: 1,
                composite: CompositeProgramDefinition(steps: [cameraStep], audioChannels: [audioChannel]),
                inputDevices: [ProgramInputDeviceRecord(name: "Camera", kind: .video)]
            )],
            inputDevices: [WorkspaceInputDeviceRecord(name: "Camera", kind: .video)],
            audioChannels: [audioChannel],
            visions: [WorkspaceVisionDefinition(source: .inputDevice(name: "Camera"))],
            videoComponents: [WorkspaceVideoComponentRecord(
                name: "Camera Component",
                inputDeviceID: "Camera"
            )]
        )

        let removedInputDevice = workspace.removeInputDevice(named: "Camera")
        #expect(removedInputDevice)
        #expect(workspace.inputDevices.isEmpty)
        #expect(workspace.programs[0].inputDevices.isEmpty)
        if case let .inputCameraDevice(cameraComponent) = workspace.programs[0].composite.steps[0].component {
            #expect(cameraComponent.inputDeviceID == nil)
        } else {
            Issue.record("Expected camera input component")
        }
        if case let .inputAudioDevice(audioComponent) = workspace.audioChannels[0].component {
            #expect(audioComponent.inputDeviceID == nil)
        } else {
            Issue.record("Expected audio input component")
        }
        #expect(workspace.videoComponents[0].inputDeviceID == nil)
        #expect(workspace.visions[0].source == .currentProgramOutput)
        #expect(workspace.outputConfiguration.videoPTSMasterInputDeviceID == nil)
    }

    @Test
    func programRenameUpdatesTheSelectedProgramInTheSameWorkspaceSnapshot() throws {
        var workspace = WorkspaceDefinition(
            programs: [SavedProgramDefinitionRecord(
                name: "Gameplay",
                canvasWidth: 1920,
                canvasHeight: 1080,
                frameRateNumerator: 60,
                frameRateDenominator: 1,
                composite: CompositeProgramDefinition()
            )]
        )
        var preferences = WorkspacePreferences(selectedProgramName: "Gameplay")

        try workspace.renameProgram(
            from: "Gameplay",
            to: "Intermission",
            preferences: &preferences
        )

        #expect(workspace.programs.first?.name == "Intermission")
        #expect(preferences.selectedProgramName == "Intermission")
    }

    @Test
    func rejectedRenameDoesNotPartiallyMutateWorkspaceOrPreferences() {
        let originalWorkspace = WorkspaceDefinition(
            inputDevices: [
                WorkspaceInputDeviceRecord(name: "Camera", kind: .video),
                WorkspaceInputDeviceRecord(name: "Microphone", kind: .audio),
            ]
        )
        let originalPreferences = WorkspacePreferences(
            programPreferences: ProgramPreferences(videoMutedByInputDeviceName: ["Camera": true])
        )
        var workspace = originalWorkspace
        var preferences = originalPreferences

        #expect(throws: WorkspaceRenameError.duplicateName("Microphone")) {
            try workspace.renameInputDevice(from: "Camera", to: "Microphone", preferences: &preferences)
        }
        #expect(workspace == originalWorkspace)
        #expect(preferences == originalPreferences)
    }
}
