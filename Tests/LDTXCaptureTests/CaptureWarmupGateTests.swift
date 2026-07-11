// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import LDTXCapture
import XCTest

final class CaptureWarmupGateTests: XCTestCase {
    func testDiscardsAllSamplesUntilEveryAudioFormatIsStable() {
        let gate = CaptureWarmupGate(
            requiredAudioDeviceIDs: ["first", "second"],
            requiredConsecutiveSampleCount: 2
        )
        let format = makeFormat(sampleRate: 48_000)

        XCTAssertEqual(gate.observe(audioFormat: nil, deviceID: "camera", kind: .video), .skipped)
        XCTAssertEqual(gate.observe(audioFormat: format, deviceID: "first", kind: .audio), .skipped)
        XCTAssertEqual(gate.observe(audioFormat: format, deviceID: "first", kind: .audio), .skipped)
        XCTAssertEqual(gate.observe(audioFormat: format, deviceID: "second", kind: .audio), .skipped)
        XCTAssertEqual(gate.observe(audioFormat: format, deviceID: "second", kind: .audio), .opened)
        XCTAssertEqual(gate.observe(audioFormat: nil, deviceID: "camera", kind: .video), .accepted)
    }

    func testDifferentCandidateRestartsConsecutiveCount() {
        let gate = CaptureWarmupGate(
            requiredAudioDeviceIDs: ["audio"],
            requiredConsecutiveSampleCount: 3
        )
        let first = makeFormat(sampleRate: 44_100)
        let second = makeFormat(sampleRate: 48_000)

        XCTAssertEqual(gate.observe(audioFormat: first, deviceID: "audio", kind: .audio), .skipped)
        XCTAssertEqual(gate.observe(audioFormat: second, deviceID: "audio", kind: .audio), .skipped)
        XCTAssertEqual(gate.observe(audioFormat: second, deviceID: "audio", kind: .audio), .skipped)
        XCTAssertEqual(gate.observe(audioFormat: second, deviceID: "audio", kind: .audio), .opened)
        XCTAssertEqual(gate.stableAudioFormatsByDeviceID["audio"], second)
    }

    func testReportsFormatChangeAfterOpeningAndRejectsChangedSample() {
        let first = makeFormat(sampleRate: 48_000)
        let second = makeFormat(sampleRate: 44_100)
        let gate = CaptureWarmupGate(
            requiredAudioDeviceIDs: ["audio"],
            requiredConsecutiveSampleCount: 1
        )

        XCTAssertEqual(gate.observe(audioFormat: first, deviceID: "audio", kind: .audio), .opened)
        XCTAssertEqual(
            gate.observe(audioFormat: second, deviceID: "audio", kind: .audio),
            .audioFormatChanged(deviceID: "audio", previous: first, current: second)
        )
    }

    func testVideoOnlySessionOpensImmediately() {
        let gate = CaptureWarmupGate(requiredAudioDeviceIDs: [])
        XCTAssertEqual(gate.observe(audioFormat: nil, deviceID: "camera", kind: .video), .accepted)
    }

    private func makeFormat(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}
