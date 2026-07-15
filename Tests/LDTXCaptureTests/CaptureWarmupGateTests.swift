// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import LDTXCapture
import Testing

struct CaptureWarmupGateTests {
    @Test func discardsAllSamplesUntilEveryAudioFormatIsStable() {
        let gate = CaptureWarmupGate(
            requiredAudioDeviceIDs: ["first", "second"],
            requiredConsecutiveSampleCount: 2
        )
        let format = makeFormat(sampleRate: 48_000)

        #expect(gate.observe(audioFormat: nil, deviceID: "camera", kind: .video) == .skipped)
        #expect(gate.observe(audioFormat: format, deviceID: "first", kind: .audio) == .skipped)
        #expect(gate.observe(audioFormat: format, deviceID: "first", kind: .audio) == .skipped)
        #expect(gate.observe(audioFormat: format, deviceID: "second", kind: .audio) == .skipped)
        #expect(gate.observe(audioFormat: format, deviceID: "second", kind: .audio) == .opened)
        #expect(gate.observe(audioFormat: nil, deviceID: "camera", kind: .video) == .accepted)
    }

    @Test func differentCandidateRestartsConsecutiveCount() {
        let gate = CaptureWarmupGate(
            requiredAudioDeviceIDs: ["audio"],
            requiredConsecutiveSampleCount: 3
        )
        let first = makeFormat(sampleRate: 44_100)
        let second = makeFormat(sampleRate: 48_000)

        #expect(gate.observe(audioFormat: first, deviceID: "audio", kind: .audio) == .skipped)
        #expect(gate.observe(audioFormat: second, deviceID: "audio", kind: .audio) == .skipped)
        #expect(gate.observe(audioFormat: second, deviceID: "audio", kind: .audio) == .skipped)
        #expect(gate.observe(audioFormat: second, deviceID: "audio", kind: .audio) == .opened)
        #expect(gate.stableAudioFormatsByDeviceID["audio"] == second)
    }

    @Test func reportsFormatChangeAfterOpeningAndRejectsChangedSample() {
        let first = makeFormat(sampleRate: 48_000)
        let second = makeFormat(sampleRate: 44_100)
        let gate = CaptureWarmupGate(
            requiredAudioDeviceIDs: ["audio"],
            requiredConsecutiveSampleCount: 1
        )

        #expect(gate.observe(audioFormat: first, deviceID: "audio", kind: .audio) == .opened)
        #expect(gate.observe(audioFormat: second, deviceID: "audio", kind: .audio) == .audioFormatChanged(deviceID: "audio", previous: first, current: second))
    }

    @Test func videoOnlySessionOpensImmediately() {
        let gate = CaptureWarmupGate(requiredAudioDeviceIDs: [])
        #expect(gate.observe(audioFormat: nil, deviceID: "camera", kind: .video) == .accepted)
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
