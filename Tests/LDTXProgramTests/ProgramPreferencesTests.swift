// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import Testing

struct ProgramPreferencesTests {
    @Test func fillComponentDefinitionsAreIdentifiedAsSharedAppearanceComponents() {
        #expect(ProgramComponentDefinition.fillSolidColor.isFill)
        #expect(ProgramComponentDefinition.fillLinearGradient.isFill)
        #expect(ProgramComponentDefinition.fillRadialGradient.isFill)
        #expect(ProgramComponentDefinition.fillConicGradient.isFill)
        #expect(!ProgramComponentDefinition.inputCameraDevice.isFill)
        #expect(!ProgramComponentDefinition.clock.isFill)
        #expect(!ProgramComponentDefinition.testPattern.isFill)
    }

    @Test func videoLayerMuteIsScopedToTheProgramLayer() {
        let preferences = ProgramPreferences(videoLayersByProgramName: [
            "Program A": [VideoLayerPreference(componentName: "Camera", isMuted: true)],
            "Program B": [VideoLayerPreference(componentName: "Camera", isMuted: false)]
        ])

        #expect(preferences.isVideoLayerMuted(componentName: "Camera", programName: "Program A"))
        #expect(!preferences.isVideoLayerMuted(componentName: "Camera", programName: "Program B"))
        #expect(!preferences.isVideoLayerMuted(componentName: "Missing", programName: "Program A"))
    }

    @Test func inputDeviceRenameAndRemovalUpdateDirectVideoLayers() {
        var preferences = ProgramPreferences(videoLayersByProgramName: [
            "Program": [
                VideoLayerPreference(componentName: "Camera A", isMuted: true),
                VideoLayerPreference(componentName: "Title")
            ]
        ])

        preferences.renameInputDevice(from: "Camera A", to: "Camera B")
        #expect(preferences.videoLayers(forProgramNamed: "Program").map(\.componentName) == ["Camera B", "Title"])
        #expect(preferences.isVideoLayerMuted(componentName: "Camera B", programName: "Program"))

        preferences.removeInputDevice(named: "Camera B")
        #expect(preferences.videoLayers(forProgramNamed: "Program").map(\.componentName) == ["Title"])
    }

    @Test func audioMutePreservesTheConfiguredGain() {
        let channel = ProgramAudioChannel(
            name: "Microphone",
            component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "1-Mic"))
        )
        var preferences = ProgramPreferences()
        preferences.setAudioChannelGain(0.5, for: channel, in: [channel])
        preferences.setAudioMuted(true, inputDeviceName: "1-Mic")

        #expect(preferences.audioChannelGain(for: channel, in: [channel]) == 0.5)
        #expect(preferences.outputAudioChannelGain(for: channel, in: [channel]) == 0)

        preferences.setAudioMuted(false, inputDeviceName: "1-Mic")
        #expect(preferences.outputAudioChannelGain(for: channel, in: [channel]) == 0.5)
    }

    private let firstID = "First"
    private let secondID = "Second"

    @Test func onlyVideoInputsSupportProgramVideoMute() {
        #expect(ProgramInputDeviceKind.video.supportsProgramVideoMute)
        #expect(!ProgramInputDeviceKind.audio.supportsProgramVideoMute)
        #expect(!ProgramInputDeviceKind.unspecified.supportsProgramVideoMute)
    }

    @Test func videoMuteUsesCanonicalPercentEncodedInputDeviceName() {
        var preferences = ProgramPreferences()

        preferences.setVideoMuted(true, inputDeviceName: "Camera 端末/%")

        #expect(preferences.videoMutedByInputDeviceName == ["Camera%20%E7%AB%AF%E6%9C%AB%2F%25": true])
        #expect(preferences.isVideoMuted(inputDeviceName: "Camera 端末/%"))
    }

    @Test func explicitUnmuteIsStoredAndRenameMovesTheEntry() {
        var preferences = ProgramPreferences()
        preferences.setVideoMuted(false, inputDeviceName: "Camera A")

        preferences.renameInputDevice(from: "Camera A", to: "Camera B")

        #expect(preferences.videoMutedByInputDeviceName == ["Camera%20B": false])
        #expect(!preferences.isVideoMuted(inputDeviceName: "Camera A"))
        #expect(!preferences.isVideoMuted(inputDeviceName: "Camera B"))
    }

    @Test func renameWithConflictingAudioMuteKeysClearsAudioMutePreferences() {
        var preferences = ProgramPreferences()
        preferences.setAudioMuted(true, inputDeviceName: "Camera A")
        preferences.setAudioMuted(false, inputDeviceName: "Camera B")

        preferences.renameInputDevice(from: "Camera A", to: "Camera B")

        #expect(preferences.audioMutedByInputDeviceName.isEmpty)
    }

    @Test func audioChannelGainDecibelConversionUsesExpectedRange() {
        #expect(abs(ProgramPreferences.linearAudioChannelGain(fromDecibels: -80) - 0.0001) <= 0.000_000_1)
        #expect(abs(ProgramPreferences.linearAudioChannelGain(fromDecibels: 0) - 1.0) <= 0.000_000_1)
        #expect(abs(ProgramPreferences.linearAudioChannelGain(fromDecibels: 20) - 10.0) <= 0.000_000_1)
    }

    @Test func audioChannelGainClampsToMinus80ThroughPlus20Decibels() {
        #expect(abs(ProgramPreferences.clampedAudioChannelGain(0) - ProgramPreferences.minimumAudioChannelGain) <= 0.000_000_1)
        #expect(abs(ProgramPreferences.clampedAudioChannelGain(100) - ProgramPreferences.maximumAudioChannelGain) <= 0.000_000_1)
        #expect(ProgramPreferences.clampedAudioChannelGain(.nan) == 1.0)
    }

    @Test func setAudioChannelGainStoresClampedLinearGain() throws {
        let composite = CompositeProgramDefinition(audioChannels: [
            ProgramAudioChannel(
                id: firstID,
                component: .inputAudioDevice(InputAudioDeviceComponent())
            )
        ])
        let channel = composite.audioChannels[0]
        var preferences = ProgramPreferences()

        preferences.setAudioChannelGain(100, for: channel, in: composite)

        let gain = try #require(preferences.audioChannelGainsByName[composite.audioChannelKey(for: channel)])
        #expect(abs(gain - ProgramPreferences.maximumAudioChannelGain) <= 0.000_000_1)
    }

    @Test func audioChannelUsesExplicitNameAsKey() throws {
        let composite = CompositeProgramDefinition(audioChannels: [
            ProgramAudioChannel(
                id: firstID,
                component: .inputAudioDevice(InputAudioDeviceComponent())
            )
        ])
        let channel = composite.audioChannels[0]
        var preferences = ProgramPreferences()

        preferences.setAudioChannelGain(0.5, for: channel, in: composite)

        let gain = try #require(preferences.audioChannelGainsByName[composite.audioChannelKey(for: channel)])
        #expect(abs(gain - 0.5) <= 0.000_000_1)
        #expect(composite.audioChannelDisplayName(for: channel) == firstID)
    }

    @Test func inputCameraDeviceKeysUseExplicitNames() {
        let composite = CompositeProgramDefinition(steps: [
            CompositeProgramStep(id: firstID, component: .inputCameraDevice(InputDeviceComponent())),
            CompositeProgramStep(component: .fillSolidColor(FillSolidColorComponent())),
            CompositeProgramStep(id: secondID, component: .inputCameraDevice(InputDeviceComponent()))
        ])

        #expect(composite.inputCameraDeviceMappingKey(for: composite.steps[0]) == firstID)
        #expect(composite.inputCameraDeviceMappingKey(for: composite.steps[2]) == secondID)
        #expect(composite.inputCameraDeviceDisplayName(for: composite.steps[2]) == secondID)
    }

    @Test func explicitVideoComponentDisplayNameOverridesGeneratedName() {
        let composite = CompositeProgramDefinition(steps: [
            CompositeProgramStep(
                id: firstID,
                displayName: "Main Camera",
                component: .inputCameraDevice(InputDeviceComponent())
            )
        ])

        #expect(composite.videoComponentDisplayName(for: composite.steps[0]) == "Main Camera")
        #expect(composite.inputCameraDeviceDisplayName(for: composite.steps[0]) == "Main Camera")
        #expect(composite.inputCameraDeviceMappingKey(for: composite.steps[0]) == "Main Camera")
    }

    @Test func reorderingKeepsStableInputCameraDeviceKeys() {
        let firstStep = CompositeProgramStep(id: firstID, component: .inputCameraDevice(InputDeviceComponent()))
        let secondStep = CompositeProgramStep(id: secondID, component: .inputCameraDevice(InputDeviceComponent()))
        var composite = CompositeProgramDefinition(steps: [
            firstStep,
            secondStep
        ])
        let firstKey = composite.inputCameraDeviceMappingKey(for: firstStep)
        let secondKey = composite.inputCameraDeviceMappingKey(for: secondStep)

        composite.steps.swapAt(0, 1)

        #expect(composite.inputCameraDeviceMappingKey(for: firstStep) == firstKey)
        #expect(composite.inputCameraDeviceMappingKey(for: secondStep) == secondKey)
    }

    @Test func reorderingKeepsStableAudioChannelKeys() {
        let firstChannel = ProgramAudioChannel(id: firstID, component: .inputAudioDevice(InputAudioDeviceComponent()))
        let secondChannel = ProgramAudioChannel(id: secondID, component: .inputAudioDevice(InputAudioDeviceComponent()))
        var composite = CompositeProgramDefinition(audioChannels: [
            firstChannel,
            secondChannel
        ])
        let firstKey = composite.audioChannelKey(for: firstChannel)
        let secondKey = composite.audioChannelKey(for: secondChannel)

        composite.audioChannels.swapAt(0, 1)

        #expect(composite.audioChannelKey(for: firstChannel) == firstKey)
        #expect(composite.audioChannelKey(for: secondChannel) == secondKey)
    }

    @Test func resolvedWorkspaceAudioChannelsDeriveInputAudioChannelsFromWorkspaceInputDevices() throws {
        let workspaceInputDevices = [
            ProgramInputDeviceRecord(
                name: "Desk Mic",
                kind: .audio
            )
        ]

        let resolvedChannels = workspaceInputDevices.resolvedWorkspaceAudioChannels(from: [])

        #expect(resolvedChannels.count == 1)
        let channel = try #require(resolvedChannels.first)
        guard case let .inputAudioDevice(payload) = channel.component else {
            Issue.record("Expected an input audio device channel.")
            return
        }
        #expect(payload.inputDeviceID == "Desk Mic")
        #expect(workspaceInputDevices.resolvedWorkspaceAudioChannels(from: [])[0].id == resolvedChannels[0].id)
    }

    @Test func resolvedWorkspaceAudioChannelsDropStaleInputDeviceChannelsButKeepGeneratedAudio() {
        let liveChannel = ProgramAudioChannel(
            id: firstID,
            component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "Desk Mic"))
        )
        let staleChannel = ProgramAudioChannel(
            id: secondID,
            component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "Missing Mic"))
        )
        let silentChannel = ProgramAudioChannel(component: .silentAudio)
        let workspaceInputDevices = [
            ProgramInputDeviceRecord(
                name: "Desk Mic",
                kind: .audio
            )
        ]

        let resolvedChannels = workspaceInputDevices.resolvedWorkspaceAudioChannels(
            from: [liveChannel, staleChannel, silentChannel]
        )

        #expect(resolvedChannels.count == 2)
        #expect(resolvedChannels[0] == liveChannel)
        #expect(resolvedChannels[1] == silentChannel)
    }
}
