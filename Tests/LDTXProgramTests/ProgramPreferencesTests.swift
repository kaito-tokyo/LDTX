// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import Testing

struct ProgramPreferencesTests {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

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

    @Test func unnamedAudioChannelUsesGeneratedKey() throws {
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
        #expect(composite.audioChannelDisplayName(for: channel) == "Input Audio Device 1")
    }

    @Test func legacyAudioChannelGainKeyMigratesOnWrite() throws {
        let composite = CompositeProgramDefinition(audioChannels: [
            ProgramAudioChannel(
                id: firstID,
                component: .inputAudioDevice(InputAudioDeviceComponent())
            )
        ])
        let channel = composite.audioChannels[0]
        let legacyKey = composite.legacyAudioChannelKey(for: channel)
        var preferences = ProgramPreferences(audioChannelGainsByName: [legacyKey: 0.5])

        #expect(abs(preferences.audioChannelGain(for: channel, in: composite) - 0.5) <= 0.000_000_1)

        preferences.setAudioChannelGain(0.75, for: channel, in: composite)

        #expect(preferences.audioChannelGainsByName[legacyKey] == nil)
        let gain = try #require(preferences.audioChannelGainsByName[composite.audioChannelKey(for: channel)])
        #expect(abs(gain - 0.75) <= 0.000_000_1)
    }

    @Test func generatedInputCameraDeviceKeysStayUniqueWithoutNames() {
        let composite = CompositeProgramDefinition(steps: [
            CompositeProgramStep(id: firstID, component: .inputCameraDevice(InputDeviceComponent())),
            CompositeProgramStep(component: .fillSolidColor(FillSolidColorComponent())),
            CompositeProgramStep(id: secondID, component: .inputCameraDevice(InputDeviceComponent()))
        ])

        #expect(composite.inputCameraDeviceMappingKey(for: composite.steps[0]) == "inputCameraDevice:00000000-0000-0000-0000-000000000001")
        #expect(composite.inputCameraDeviceMappingKey(for: composite.steps[2]) == "inputCameraDevice:00000000-0000-0000-0000-000000000002")
        #expect(composite.inputCameraDeviceDisplayName(for: composite.steps[2]) == "Input Camera Device 2")
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
        #expect(composite.inputCameraDeviceMappingKey(for: composite.steps[0]) == "inputCameraDevice:00000000-0000-0000-0000-000000000001")
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
                id: "workspace-audio-1",
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
        #expect(payload.inputDeviceID == "workspace-audio-1")
        #expect(workspaceInputDevices.resolvedWorkspaceAudioChannels(from: [])[0].id == resolvedChannels[0].id)
    }

    @Test func resolvedWorkspaceAudioChannelsDropStaleInputDeviceChannelsButKeepGeneratedAudio() {
        let liveChannel = ProgramAudioChannel(
            id: firstID,
            component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "workspace-audio-1"))
        )
        let staleChannel = ProgramAudioChannel(
            id: secondID,
            component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "workspace-audio-2"))
        )
        let silentChannel = ProgramAudioChannel(component: .silentAudio)
        let workspaceInputDevices = [
            ProgramInputDeviceRecord(
                id: "workspace-audio-1",
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
