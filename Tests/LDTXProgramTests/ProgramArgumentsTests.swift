// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import XCTest

final class ProgramArgumentsTests: XCTestCase {
    func testAudioChannelGainDecibelConversionUsesExpectedRange() {
        XCTAssertEqual(
            ProgramArguments.linearAudioChannelGain(fromDecibels: -80),
            0.0001,
            accuracy: 0.000_000_1
        )
        XCTAssertEqual(
            ProgramArguments.linearAudioChannelGain(fromDecibels: 0),
            1.0,
            accuracy: 0.000_000_1
        )
        XCTAssertEqual(
            ProgramArguments.linearAudioChannelGain(fromDecibels: 20),
            10.0,
            accuracy: 0.000_000_1
        )
    }

    func testAudioChannelGainClampsToMinus80ThroughPlus20Decibels() {
        XCTAssertEqual(
            ProgramArguments.clampedAudioChannelGain(0),
            ProgramArguments.minimumAudioChannelGain,
            accuracy: 0.000_000_1
        )
        XCTAssertEqual(
            ProgramArguments.clampedAudioChannelGain(100),
            ProgramArguments.maximumAudioChannelGain,
            accuracy: 0.000_000_1
        )
        XCTAssertEqual(ProgramArguments.clampedAudioChannelGain(.nan), 1.0)
    }

    func testSetAudioChannelGainStoresClampedLinearGain() throws {
        let composite = CompositeProgramDefinition(audioChannels: [
            ProgramAudioChannel(name: "Mic", component: .inputAudioDevice(InputAudioDeviceComponent()))
        ])
        let channel = composite.audioChannels[0]
        var arguments = ProgramArguments()

        arguments.setAudioChannelGain(100, for: channel, in: composite)

        XCTAssertEqual(
            try XCTUnwrap(arguments.audioChannelGainsByName["Mic"]),
            ProgramArguments.maximumAudioChannelGain,
            accuracy: 0.000_000_1
        )
    }

    func testUnnamedAudioChannelUsesGeneratedKey() throws {
        let composite = CompositeProgramDefinition(audioChannels: [
            ProgramAudioChannel(component: .inputAudioDevice(InputAudioDeviceComponent()))
        ])
        let channel = composite.audioChannels[0]
        var arguments = ProgramArguments()

        arguments.setAudioChannelGain(0.5, for: channel, in: composite)

        XCTAssertEqual(
            try XCTUnwrap(arguments.audioChannelGainsByName["inputAudioDevice 1"]),
            0.5,
            accuracy: 0.000_000_1
        )
        XCTAssertEqual(composite.audioChannelDisplayName(for: channel), "Input Audio Device 1")
    }
}
