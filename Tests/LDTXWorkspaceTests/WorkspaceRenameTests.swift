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
            automations: [WorkspaceAutomationDefinition(
                actions: [.selectInputDevice(inputDeviceName: "Camera")]
            )]
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
        #expect(workspace.automations[0].actions == [.selectInputDevice(inputDeviceName: "Front Camera")])
        #expect(preferences.programPreferences.isVideoMuted(inputDeviceName: "Front Camera"))
        #expect(preferences.physicalDeviceIDsByInputDeviceID == ["Front Camera": "physical-camera"])
    }

    @Test
    func visionAndAutomationRenameUpdateTheirReferences() throws {
        var workspace = WorkspaceDefinition(
            visions: [WorkspaceVisionDefinition(name: "Vision", postActionAutomationName: "Automation")],
            automations: [WorkspaceAutomationDefinition(
                name: "Automation",
                actions: [.analyzeVision(visionName: "Vision")]
            )]
        )

        try workspace.renameVision(from: "Vision", to: "Gameplay Vision")
        try workspace.renameAutomation(from: "Automation", to: "After Analysis")

        #expect(workspace.automations[0].actions == [.analyzeVision(visionName: "Gameplay Vision")])
        #expect(workspace.visions[0].postActionAutomationName == "After Analysis")
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
