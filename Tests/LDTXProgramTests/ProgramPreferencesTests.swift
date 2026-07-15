// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import XCTest

final class ProgramPreferencesTests: XCTestCase {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    func testAudioChannelGainDecibelConversionUsesExpectedRange() {
        XCTAssertEqual(
            ProgramPreferences.linearAudioChannelGain(fromDecibels: -80),
            0.0001,
            accuracy: 0.000_000_1
        )
        XCTAssertEqual(
            ProgramPreferences.linearAudioChannelGain(fromDecibels: 0),
            1.0,
            accuracy: 0.000_000_1
        )
        XCTAssertEqual(
            ProgramPreferences.linearAudioChannelGain(fromDecibels: 20),
            10.0,
            accuracy: 0.000_000_1
        )
    }

    func testAudioChannelGainClampsToMinus80ThroughPlus20Decibels() {
        XCTAssertEqual(
            ProgramPreferences.clampedAudioChannelGain(0),
            ProgramPreferences.minimumAudioChannelGain,
            accuracy: 0.000_000_1
        )
        XCTAssertEqual(
            ProgramPreferences.clampedAudioChannelGain(100),
            ProgramPreferences.maximumAudioChannelGain,
            accuracy: 0.000_000_1
        )
        XCTAssertEqual(ProgramPreferences.clampedAudioChannelGain(.nan), 1.0)
    }

    func testSetAudioChannelGainStoresClampedLinearGain() throws {
        let composite = CompositeProgramDefinition(audioChannels: [
            ProgramAudioChannel(
                id: firstID,
                component: .inputAudioDevice(InputAudioDeviceComponent())
            )
        ])
        let channel = composite.audioChannels[0]
        var preferences = ProgramPreferences()

        preferences.setAudioChannelGain(100, for: channel, in: composite)

        XCTAssertEqual(
            try XCTUnwrap(preferences.audioChannelGainsByName[composite.audioChannelKey(for: channel)]),
            ProgramPreferences.maximumAudioChannelGain,
            accuracy: 0.000_000_1
        )
    }

    func testUnnamedAudioChannelUsesGeneratedKey() throws {
        let composite = CompositeProgramDefinition(audioChannels: [
            ProgramAudioChannel(
                id: firstID,
                component: .inputAudioDevice(InputAudioDeviceComponent())
            )
        ])
        let channel = composite.audioChannels[0]
        var preferences = ProgramPreferences()

        preferences.setAudioChannelGain(0.5, for: channel, in: composite)

        XCTAssertEqual(
            try XCTUnwrap(preferences.audioChannelGainsByName[composite.audioChannelKey(for: channel)]),
            0.5,
            accuracy: 0.000_000_1
        )
        XCTAssertEqual(composite.audioChannelDisplayName(for: channel), "Input Audio Device 1")
    }

    func testLegacyAudioChannelGainKeyMigratesOnWrite() throws {
        let composite = CompositeProgramDefinition(audioChannels: [
            ProgramAudioChannel(
                id: firstID,
                component: .inputAudioDevice(InputAudioDeviceComponent())
            )
        ])
        let channel = composite.audioChannels[0]
        let legacyKey = composite.legacyAudioChannelKey(for: channel)
        var preferences = ProgramPreferences(audioChannelGainsByName: [legacyKey: 0.5])

        XCTAssertEqual(preferences.audioChannelGain(for: channel, in: composite), 0.5, accuracy: 0.000_000_1)

        preferences.setAudioChannelGain(0.75, for: channel, in: composite)

        XCTAssertNil(preferences.audioChannelGainsByName[legacyKey])
        XCTAssertEqual(
            try XCTUnwrap(preferences.audioChannelGainsByName[composite.audioChannelKey(for: channel)]),
            0.75,
            accuracy: 0.000_000_1
        )
    }

    func testGeneratedInputCameraDeviceKeysStayUniqueWithoutNames() {
        let composite = CompositeProgramDefinition(steps: [
            CompositeProgramStep(id: firstID, component: .inputCameraDevice(InputDeviceComponent())),
            CompositeProgramStep(component: .fillSolidColor(FillSolidColorComponent())),
            CompositeProgramStep(id: secondID, component: .inputCameraDevice(InputDeviceComponent()))
        ])

        XCTAssertEqual(
            composite.inputCameraDeviceMappingKey(for: composite.steps[0]),
            "inputCameraDevice:00000000-0000-0000-0000-000000000001"
        )
        XCTAssertEqual(
            composite.inputCameraDeviceMappingKey(for: composite.steps[2]),
            "inputCameraDevice:00000000-0000-0000-0000-000000000002"
        )
        XCTAssertEqual(composite.inputCameraDeviceDisplayName(for: composite.steps[2]), "Input Camera Device 2")
    }

    func testExplicitVideoComponentDisplayNameOverridesGeneratedName() {
        let composite = CompositeProgramDefinition(steps: [
            CompositeProgramStep(
                id: firstID,
                displayName: "Main Camera",
                component: .inputCameraDevice(InputDeviceComponent())
            )
        ])

        XCTAssertEqual(composite.videoComponentDisplayName(for: composite.steps[0]), "Main Camera")
        XCTAssertEqual(composite.inputCameraDeviceDisplayName(for: composite.steps[0]), "Main Camera")
        XCTAssertEqual(
            composite.inputCameraDeviceMappingKey(for: composite.steps[0]),
            "inputCameraDevice:00000000-0000-0000-0000-000000000001"
        )
    }

    func testReorderingKeepsStableInputCameraDeviceKeys() {
        let firstStep = CompositeProgramStep(id: firstID, component: .inputCameraDevice(InputDeviceComponent()))
        let secondStep = CompositeProgramStep(id: secondID, component: .inputCameraDevice(InputDeviceComponent()))
        var composite = CompositeProgramDefinition(steps: [
            firstStep,
            secondStep
        ])
        let firstKey = composite.inputCameraDeviceMappingKey(for: firstStep)
        let secondKey = composite.inputCameraDeviceMappingKey(for: secondStep)

        composite.steps.swapAt(0, 1)

        XCTAssertEqual(composite.inputCameraDeviceMappingKey(for: firstStep), firstKey)
        XCTAssertEqual(composite.inputCameraDeviceMappingKey(for: secondStep), secondKey)
    }

    func testReorderingKeepsStableAudioChannelKeys() {
        let firstChannel = ProgramAudioChannel(id: firstID, component: .inputAudioDevice(InputAudioDeviceComponent()))
        let secondChannel = ProgramAudioChannel(id: secondID, component: .inputAudioDevice(InputAudioDeviceComponent()))
        var composite = CompositeProgramDefinition(audioChannels: [
            firstChannel,
            secondChannel
        ])
        let firstKey = composite.audioChannelKey(for: firstChannel)
        let secondKey = composite.audioChannelKey(for: secondChannel)

        composite.audioChannels.swapAt(0, 1)

        XCTAssertEqual(composite.audioChannelKey(for: firstChannel), firstKey)
        XCTAssertEqual(composite.audioChannelKey(for: secondChannel), secondKey)
    }

    func testResolvedWorkspaceAudioChannelsDeriveInputAudioChannelsFromWorkspaceInputDevices() {
        let workspaceInputDevices = [
            ProgramInputDeviceRecord(
                id: "workspace-audio-1",
                name: "Desk Mic",
                kind: .audio
            )
        ]

        let resolvedChannels = workspaceInputDevices.resolvedWorkspaceAudioChannels(from: [])

        XCTAssertEqual(resolvedChannels.count, 1)
        guard case let .inputAudioDevice(payload) = resolvedChannels[0].component else {
            return XCTFail("Expected an input audio device channel.")
        }
        XCTAssertEqual(payload.inputDeviceID, "workspace-audio-1")
        XCTAssertEqual(
            workspaceInputDevices.resolvedWorkspaceAudioChannels(from: [])[0].id,
            resolvedChannels[0].id
        )
    }

    func testResolvedWorkspaceAudioChannelsDropStaleInputDeviceChannelsButKeepGeneratedAudio() {
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

        XCTAssertEqual(resolvedChannels.count, 2)
        XCTAssertEqual(resolvedChannels[0], liveChannel)
        XCTAssertEqual(resolvedChannels[1], silentChannel)
    }
}
