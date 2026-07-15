// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import LDTXAudioEngine
import LDTXMediaTiming
import Testing

@testable import LDTXProgramRuntime

@Suite
struct ProgramAudioMonitorMixerTests {
    private let sampleRate: CMTimeScale = 48_000

    @Test func timingAnchorKeepsFirstVideoPTSForWholeGeneration() {
        let timingAnchor = ProgramAudioMonitorTimingAnchor()
        let firstPTS = CMTime(value: 4_000_000_000, timescale: sampleRate)
        let laterPTS = CMTime(value: firstPTS.value + 8_000, timescale: sampleRate)

        timingAnchor.noteVideoPresentationTime(firstPTS)
        let firstSnapshot = timingAnchor.snapshot()
        timingAnchor.noteVideoPresentationTime(laterPTS)
        let laterSnapshot = timingAnchor.snapshot()

        #expect(firstSnapshot?.presentationTime == firstPTS)
        #expect(laterSnapshot?.presentationTime == firstPTS)
        #expect(laterSnapshot?.generation == firstSnapshot?.generation)
    }

    @Test func independentlyStartedAudioClocksUseSameSessionAnchor() throws {
        let timingAnchor = ProgramAudioMonitorTimingAnchor()
        let sessionPTS = CMTime(value: 4_000_000_000, timescale: sampleRate)
        timingAnchor.noteVideoPresentationTime(sessionPTS)

        let firstSnapshot = try #require(timingAnchor.snapshot())
        let firstClock = try AudioFramePTSClock(sampleRate: Int(sampleRate))
        let firstAudioPTS = try firstClock.nextPresentationTime(
            anchorPresentationTime: firstSnapshot.presentationTime,
            frameCount: 1_024
        )

        timingAnchor.noteVideoPresentationTime(
            CMTime(value: sessionPTS.value + 12_000, timescale: sampleRate)
        )
        let delayedSnapshot = try #require(timingAnchor.snapshot())
        let delayedClock = try AudioFramePTSClock(sampleRate: Int(sampleRate))
        let delayedAudioPTS = try delayedClock.nextPresentationTime(
            anchorPresentationTime: delayedSnapshot.presentationTime,
            frameCount: 1_024
        )

        #expect(firstAudioPTS == sessionPTS)
        #expect(delayedAudioPTS == sessionPTS)
    }

    @Test func timingAnchorResetStartsNewGeneration() throws {
        let timingAnchor = ProgramAudioMonitorTimingAnchor()
        timingAnchor.noteVideoPresentationTime(CMTime(value: 100, timescale: sampleRate))
        let firstGeneration = try #require(timingAnchor.snapshot()).generation

        timingAnchor.reset()
        #expect(timingAnchor.snapshot() == nil)
        let nextPTS = CMTime(value: 1_000, timescale: sampleRate)
        timingAnchor.noteVideoPresentationTime(nextPTS)
        let nextSnapshot = try #require(timingAnchor.snapshot())

        #expect(nextSnapshot.generation == firstGeneration + 1)
        #expect(nextSnapshot.presentationTime == nextPTS)
    }

    @Test func twoAudioStreamsMixAcrossPositionsRelativeToMainVideoPTS() throws {
        let scenarios: [(firstOffset: Int64, secondOffset: Int64, firstFrames: Int, secondFrames: Int)] = [
            (-4, 0, 8, 4),
            (0, -4, 4, 8),
            (-2, -1, 6, 5),
            (0, 0, 4, 4)
        ]

        for scenario in scenarios {
            let mixer = try makeMixer()
            let mainVideoPTS = CMTime(value: 10_000, timescale: sampleRate)
            mixer.insert(
                samples: stereoSamples(value: 0.25, frameCount: scenario.firstFrames),
                frameCount: scenario.firstFrames,
                presentationTime: offset(mainVideoPTS, frames: scenario.firstOffset),
                channelIndex: 0
            )
            mixer.insert(
                samples: stereoSamples(value: 0.5, frameCount: scenario.secondFrames),
                frameCount: scenario.secondFrames,
                presentationTime: offset(mainVideoPTS, frames: scenario.secondOffset),
                channelIndex: 1
            )

            let result = mixer.mixedSamples(
                frameCount: 4,
                presentationTime: mainVideoPTS,
                expectedChannelIndices: [0, 1]
            )

            #expect(result.missingChannelIndices == [], "scenario=\(scenario)")
            #expect(result.samples.count == 8)
            for sample in result.samples {
                #expect(abs(sample - 0.75) < 0.0001, "scenario=\(scenario)")
            }
        }
    }

    @Test func lateSecondStreamIsReportedMissingWithoutDroppingCompleteFirstStream() throws {
        let mixer = try makeMixer()
        let mainVideoPTS = CMTime(value: 20_000, timescale: sampleRate)
        mixer.insert(
            samples: stereoSamples(value: 0.25, frameCount: 4),
            frameCount: 4,
            presentationTime: mainVideoPTS,
            channelIndex: 0
        )
        mixer.insert(
            samples: stereoSamples(value: 0.5, frameCount: 4),
            frameCount: 4,
            presentationTime: offset(mainVideoPTS, frames: 2),
            channelIndex: 1
        )

        let result = mixer.mixedSamples(
            frameCount: 4,
            presentationTime: mainVideoPTS,
            expectedChannelIndices: [0, 1]
        )

        #expect(result.missingChannelIndices == [1])
        for sample in result.samples {
            #expect(abs(sample - 0.25) < 0.0001)
        }
    }

    @Test func partialSourceRangesAreSilentForWholeBlockAtEitherBoundary() throws {
        let scenarios: [(offset: Int64, frameCount: Int)] = [
            (-2, 4),
            (2, 4)
        ]

        for scenario in scenarios {
            let mixer = try makeMixer()
            let presentationTime = CMTime(value: 25_000, timescale: sampleRate)
            mixer.insert(
                samples: stereoSamples(value: 0.5, frameCount: scenario.frameCount),
                frameCount: scenario.frameCount,
                presentationTime: offset(presentationTime, frames: scenario.offset),
                channelIndex: 0
            )

            let result = mixer.mixedSamples(
                frameCount: 4,
                presentationTime: presentationTime,
                expectedChannelIndices: [0]
            )

            #expect(result.missingChannelIndices == [0], "scenario=\(scenario)")
            #expect(result.samples == [Float32](repeating: 0, count: 8), "scenario=\(scenario)")
        }
    }

    @Test func latePastRangeDoesNotAffectFutureOutput() throws {
        let mixer = try makeMixer()
        let emittedPresentationTime = CMTime(value: 50_000, timescale: sampleRate)
        let futurePresentationTime = offset(emittedPresentationTime, frames: 4)

        let missingResult = mixer.mixedSamples(
            frameCount: 4,
            presentationTime: emittedPresentationTime,
            expectedChannelIndices: [0]
        )
        #expect(missingResult.missingChannelIndices == [0])

        mixer.insert(
            samples: stereoSamples(value: 0.75, frameCount: 4),
            frameCount: 4,
            presentationTime: emittedPresentationTime,
            channelIndex: 0
        )

        let futureResult = mixer.mixedSamples(
            frameCount: 4,
            presentationTime: futurePresentationTime,
            expectedChannelIndices: [0]
        )
        #expect(futureResult.missingChannelIndices == [0])
        #expect(futureResult.samples == [Float32](repeating: 0, count: 8))
    }

    @Test func renderEmitsSilentBufferWhenAllExpectedSourcesAreMissing() throws {
        let recorder = AudioSampleBufferRecorder()
        var engine = LDTXAudioMixEngine(2)
        engine.setChannelGain(0, 1)
        engine.setChannelGain(1, 1)
        let mixer = try ProgramAudioMonitorMixer(
            audioEngine: engine,
            channelCount: 2,
            output: ProgramAudioMonitorOutput { sampleBuffer in
                recorder.append(sampleBuffer)
            }
        )
        let presentationTime = CMTime(value: 30_000, timescale: sampleRate)

        let missingChannelIndices = mixer.render(
            frameCount: 1_024,
            presentationTime: presentationTime,
            expectedChannelIndices: [0, 1]
        )

        #expect(missingChannelIndices == [0, 1])
        let sampleBuffer = try #require(recorder.sampleBuffers.first)
        #expect(recorder.sampleBuffers.count == 1)
        #expect(sampleBuffer.presentationTimeStamp == presentationTime)
        #expect(CMSampleBufferGetNumSamples(sampleBuffer) == 1_024)
    }

    @Test func outputDriverMaintainsContinuousClockDuringSourceUnderflow() async throws {
        let recorder = AudioSampleBufferRecorder()
        let scheduler = ManualProgramRuntimeScheduler()
        let timingAnchor = ProgramAudioMonitorTimingAnchor()
        timingAnchor.noteVideoPresentationTime(CMTime(value: 40_000, timescale: sampleRate))
        let output = ProgramAudioMonitorOutput { sampleBuffer in
            recorder.append(sampleBuffer)
        }
        let mixer = try ProgramAudioMonitorMixer(
            audioEngine: LDTXAudioMixEngine(2),
            channelCount: 2,
            output: output
        )
        let sink = try ProgramAudioMonitorOutputDriverSink(
            mixer: mixer,
            timingAnchor: timingAnchor,
            expectedChannelIndices: [0, 1],
            scheduler: scheduler
        )

        sink.render()
        scheduler.advance(byNanoseconds: 250_000_000)
        sink.render()

        let sampleBuffers = recorder.sampleBuffers
        #expect(sampleBuffers.count >= 2)
        for (first, second) in zip(sampleBuffers, sampleBuffers.dropFirst()) {
            #expect(second.presentationTimeStamp - first.presentationTimeStamp ==
                CMTime(value: 1_024, timescale: sampleRate))
        }
    }

    @Test func outputDriverWaitsForBoundedLatencyBeforeFillingMissingAudio() throws {
        let recorder = AudioSampleBufferRecorder()
        let scheduler = ManualProgramRuntimeScheduler()
        let timingAnchor = ProgramAudioMonitorTimingAnchor()
        let anchor = CMTime(value: 60_000, timescale: sampleRate)
        timingAnchor.noteVideoPresentationTime(anchor)
        let mixer = try ProgramAudioMonitorMixer(
            audioEngine: LDTXAudioMixEngine(1),
            channelCount: 1,
            output: ProgramAudioMonitorOutput { sampleBuffer in
                recorder.append(sampleBuffer)
            }
        )
        let sink = try ProgramAudioMonitorOutputDriverSink(
            mixer: mixer,
            timingAnchor: timingAnchor,
            expectedChannelIndices: [0],
            scheduler: scheduler
        )

        sink.render()
        #expect(recorder.sampleBuffers.count == 0)

        scheduler.advance(byNanoseconds: 199_999_999)
        sink.render()
        #expect(recorder.sampleBuffers.count == 0)

        scheduler.advance(byNanoseconds: 1)
        sink.render()
        let firstBuffer = try #require(recorder.sampleBuffers.first)
        #expect(recorder.sampleBuffers.count == 1)
        #expect(firstBuffer.presentationTimeStamp == anchor)
        #expect(CMSampleBufferGetNumSamples(firstBuffer) == 1_024)
    }

    private func makeMixer() throws -> ProgramAudioMonitorMixer {
        var engine = LDTXAudioMixEngine(2)
        engine.setChannelGain(0, 1)
        engine.setChannelGain(1, 1)
        return try ProgramAudioMonitorMixer(
            audioEngine: engine,
            channelCount: 2,
            output: ProgramAudioMonitorOutput()
        )
    }

    private func stereoSamples(value: Float32, frameCount: Int) -> [Float32] {
        [Float32](repeating: value, count: frameCount * 2)
    }

    private func offset(_ time: CMTime, frames: Int64) -> CMTime {
        CMTimeAdd(time, CMTime(value: frames, timescale: sampleRate))
    }
}

private final class AudioSampleBufferRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CMSampleBuffer] = []

    var sampleBuffers: [CMSampleBuffer] {
        lock.withLock { storage }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.withLock {
            storage.append(sampleBuffer)
        }
    }
}
