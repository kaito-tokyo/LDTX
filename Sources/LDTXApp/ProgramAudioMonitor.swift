// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreMedia
import Foundation
import LDTXAudioEngine
import LDTXCapture
import LDTXMedia
import LDTXProgram

final class ProgramAudioMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var audioEngine = LDTXAudioMixEngine(1)
    private var channelIndicesByKey: [String: Int32] = [:]
    private var captureServices: [CameraCaptureService] = []
    private var generatedSources: [ProgramAudioMonitorGeneratedSource] = []
    private let output = ProgramAudioMonitorOutput()
    private let outputDriveState = ProgramAudioMonitorOutputDriveState()
    private let timingAnchor = ProgramAudioMonitorTimingAnchor()

    func restart(
        composite: CompositeProgramDefinition,
        inputAudioDeviceMappings: [String: String],
        programArguments: ProgramArguments,
        programAudioDriverKey: String?,
        peakMeter: ProgramAudioPeakMeter
    ) async throws {
        let channelKeys = composite.audioChannels.map { composite.audioChannelKey(for: $0) }
        guard !channelKeys.isEmpty else {
            await stop()
            peakMeter.reset()
            return
        }

        var nextEngine = LDTXAudioMixEngine(Int32(channelKeys.count))
        let nextIndices = Dictionary(
            uniqueKeysWithValues: channelKeys.enumerated().map { index, key in
                (key, Int32(index))
            }
        )
        for (key, index) in nextIndices {
            nextEngine.setChannelGain(index, Float(programArguments.audioChannelGainsByName[key] ?? 1.0))
        }
        let audioDriverKey = Self.audioDriverKey(
            composite: composite,
            inputAudioDeviceMappings: inputAudioDeviceMappings
        )
        let selectedAudioDriverKey = Self.availableAudioDriverKey(
            selectedKey: programAudioDriverKey,
            composite: composite,
            inputAudioDeviceMappings: inputAudioDeviceMappings
        )
        let mixer = try ProgramAudioMonitorMixer(
            audioEngine: nextEngine,
            channelCount: Int32(channelKeys.count),
            output: output
        )
        outputDriveState.reset()

        let previousServices = replaceState(
            audioEngine: nextEngine,
            channelIndicesByKey: nextIndices,
            captureServices: [],
            generatedSources: []
        )
        await stop(sources: previousServices)
        peakMeter.bind(audioEngine: nextEngine, channelKeys: channelKeys)

        var startedServices: [CameraCaptureService] = []
        var startedGeneratedSources: [ProgramAudioMonitorGeneratedSource] = []
        do {
            for channel in composite.audioChannels {
                let key = composite.audioChannelKey(for: channel)
                let channelIndex = nextIndices[key] ?? 0
                switch channel.component.definition {
                case .inputAudioDevice:
                    let mappingKey = composite.inputAudioDeviceMappingKey(for: channel)
                    guard let deviceID = inputAudioDeviceMappings[mappingKey], !deviceID.isEmpty else {
                        continue
                    }
                    let drivesOutput = Self.drivesProgramAudioOutput(
                        key: key,
                        selectedAudioDriverKey: selectedAudioDriverKey,
                        audioDriverKey: audioDriverKey
                    )

                    let sink = try ProgramAudioMonitorSink(
                        channelIndex: channelIndex,
                        mixer: mixer,
                        drivesOutput: drivesOutput,
                        timingAnchor: timingAnchor,
                        outputDriveState: outputDriveState
                    )
                    let captureService = CameraCaptureService()
                    try await captureService.startAudioCapture(audioDeviceID: deviceID) { sampleBuffer, kind in
                        sink.append(sampleBuffer, kind: kind)
                    }
                    startedServices.append(captureService)
                case .testPatternAudio:
                    let drivesOutput = Self.drivesProgramAudioOutput(
                        key: key,
                        selectedAudioDriverKey: selectedAudioDriverKey,
                        audioDriverKey: audioDriverKey
                    )
                    let source = try ProgramAudioMonitorGeneratedSource(
                        channelIndex: channelIndex,
                        mixer: mixer,
                        mode: .sweepSine,
                        drivesOutput: drivesOutput,
                        timingAnchor: timingAnchor,
                        outputDriveState: outputDriveState
                    )
                    source.start()
                    startedGeneratedSources.append(source)
                case .silentAudio:
                    let drivesOutput = Self.drivesProgramAudioOutput(
                        key: key,
                        selectedAudioDriverKey: selectedAudioDriverKey,
                        audioDriverKey: audioDriverKey
                    )
                    let source = try ProgramAudioMonitorGeneratedSource(
                        channelIndex: channelIndex,
                        mixer: mixer,
                        mode: .silence,
                        drivesOutput: drivesOutput,
                        timingAnchor: timingAnchor,
                        outputDriveState: outputDriveState
                    )
                    source.start()
                    startedGeneratedSources.append(source)
                }
            }

            let fallbackSource = try ProgramAudioMonitorGeneratedSource(
                channelIndex: nil,
                mixer: mixer,
                mode: .silence,
                drivesOutput: false,
                timingAnchor: timingAnchor,
                outputDriveState: outputDriveState
            )
            fallbackSource.start()
            startedGeneratedSources.append(fallbackSource)
        } catch {
            await stop(sources: ProgramAudioMonitorRunningSources(
                captureServices: startedServices,
                generatedSources: startedGeneratedSources
            ))
            throw error
        }

        lock.withLock {
            captureServices = startedServices
            generatedSources = startedGeneratedSources
        }
    }

    private static func drivesProgramAudioOutput(
        key: String,
        selectedAudioDriverKey: String?,
        audioDriverKey: String?
    ) -> Bool {
        if let selectedAudioDriverKey {
            return key == selectedAudioDriverKey
        }
        return key == audioDriverKey
    }

    private static func audioDriverKey(
        composite: CompositeProgramDefinition,
        inputAudioDeviceMappings: [String: String]
    ) -> String? {
        for channel in composite.audioChannels {
            guard case .inputAudioDevice = channel.component,
                  let deviceID = inputAudioDeviceMappings[composite.inputAudioDeviceMappingKey(for: channel)],
                  !deviceID.isEmpty else {
                continue
            }
            return composite.audioChannelKey(for: channel)
        }

        for channel in composite.audioChannels {
            switch channel.component.definition {
            case .inputAudioDevice:
                continue
            case .silentAudio, .testPatternAudio:
                return composite.audioChannelKey(for: channel)
            }
        }
        return nil
    }

    private static func availableAudioDriverKey(
        selectedKey: String?,
        composite: CompositeProgramDefinition,
        inputAudioDeviceMappings: [String: String]
    ) -> String? {
        guard let selectedKey else {
            return nil
        }
        for channel in composite.audioChannels where composite.audioChannelKey(for: channel) == selectedKey {
            switch channel.component.definition {
            case .inputAudioDevice:
                let mappingKey = composite.inputAudioDeviceMappingKey(for: channel)
                guard let deviceID = inputAudioDeviceMappings[mappingKey], !deviceID.isEmpty else {
                    return nil
                }
                return selectedKey
            case .silentAudio, .testPatternAudio:
                return selectedKey
            }
        }
        return nil
    }

    func updateGains(
        composite: CompositeProgramDefinition,
        arguments: ProgramArguments
    ) {
        var engine: LDTXAudioMixEngine!
        let indices = lock.withLock {
            engine = audioEngine
            return channelIndicesByKey
        }

        for channel in composite.audioChannels {
            let key = composite.audioChannelKey(for: channel)
            guard let channelIndex = indices[key] else {
                continue
            }
            engine.setChannelGain(channelIndex, Float(arguments.audioChannelGain(for: channel, in: composite)))
        }
    }

    func attach(writer: SegmentedMP4Writer) {
        timingAnchor.reset()
        outputDriveState.reset()
        output.attach(writer: writer)
    }

    func detachWriter() {
        output.detachWriter()
    }

    func noteVideoPresentationTime(_ presentationTime: CMTime) {
        timingAnchor.noteVideoPresentationTime(presentationTime)
    }

    func stop() async {
        detachWriter()
        let services = replaceState(
            audioEngine: LDTXAudioMixEngine(1),
            channelIndicesByKey: [:],
            captureServices: [],
            generatedSources: []
        )
        await stop(sources: services)
    }

    private func replaceState(
        audioEngine: LDTXAudioMixEngine,
        channelIndicesByKey: [String: Int32],
        captureServices: [CameraCaptureService],
        generatedSources: [ProgramAudioMonitorGeneratedSource]
    ) -> ProgramAudioMonitorRunningSources {
        lock.withLock {
            let previousSources = ProgramAudioMonitorRunningSources(
                captureServices: self.captureServices,
                generatedSources: self.generatedSources
            )
            self.audioEngine = audioEngine
            self.channelIndicesByKey = channelIndicesByKey
            self.captureServices = captureServices
            self.generatedSources = generatedSources
            return previousSources
        }
    }

    private func stop(sources: ProgramAudioMonitorRunningSources) async {
        for source in sources.generatedSources {
            source.stop()
        }
        for service in sources.captureServices {
            await service.stop()
        }
    }
}

private struct ProgramAudioMonitorRunningSources {
    var captureServices: [CameraCaptureService]
    var generatedSources: [ProgramAudioMonitorGeneratedSource]
}

private final class ProgramAudioMonitorOutputDriveState: @unchecked Sendable {
    private let lock = NSLock()
    private var primaryOutputDriven = false

    var hasPrimaryOutputDriven: Bool {
        lock.withLock {
            primaryOutputDriven
        }
    }

    func reset() {
        lock.withLock {
            primaryOutputDriven = false
        }
    }

    func notePrimaryOutputDriven() {
        lock.withLock {
            primaryOutputDriven = true
        }
    }
}

private final class ProgramAudioMonitorTimingAnchor: @unchecked Sendable {
    private let lock = NSLock()
    private var latestVideoPresentationTime: CMTime?
    private var generation = 0

    func reset() {
        lock.withLock {
            latestVideoPresentationTime = nil
            generation += 1
        }
    }

    func noteVideoPresentationTime(_ presentationTime: CMTime) {
        guard presentationTime.isValid else { return }
        lock.withLock {
            latestVideoPresentationTime = presentationTime
        }
    }

    func snapshot() -> (presentationTime: CMTime, generation: Int)? {
        lock.withLock {
            guard let latestVideoPresentationTime else { return nil }
            return (latestVideoPresentationTime, generation)
        }
    }
}

private final class ProgramAudioMonitorSink: @unchecked Sendable {
    private let lock = NSLock()
    private let channelIndex: Int32
    private let normalizer: AudioSampleBufferNormalizer
    private let mixer: ProgramAudioMonitorMixer
    private let drivesOutput: Bool
    private let timingAnchor: ProgramAudioMonitorTimingAnchor
    private let outputDriveState: ProgramAudioMonitorOutputDriveState
    private var ptsClock: AudioFramePTSClock
    private var anchorGeneration: Int?

    init(
        channelIndex: Int32,
        mixer: ProgramAudioMonitorMixer,
        drivesOutput: Bool,
        timingAnchor: ProgramAudioMonitorTimingAnchor,
        outputDriveState: ProgramAudioMonitorOutputDriveState
    ) throws {
        self.channelIndex = channelIndex
        self.mixer = mixer
        self.drivesOutput = drivesOutput
        self.timingAnchor = timingAnchor
        self.outputDriveState = outputDriveState
        normalizer = try AudioSampleBufferNormalizer()
        ptsClock = try AudioFramePTSClock(sampleRate: AudioSampleBufferNormalizer.sampleRate)
    }

    func append(_ sampleBuffer: CMSampleBuffer, kind: CameraCaptureSampleKind) {
        guard kind == .audio else { return }

        do {
            guard let normalizedSampleBuffer = try normalizer.normalize(sampleBuffer),
                  let dataBuffer = CMSampleBufferGetDataBuffer(normalizedSampleBuffer) else {
                return
            }

            let byteCount = CMBlockBufferGetDataLength(dataBuffer)
            guard byteCount > 0 else { return }

            var samples = [Float32](repeating: 0, count: byteCount / MemoryLayout<Float32>.stride)
            let copyStatus = samples.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(
                    dataBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: buffer.baseAddress!
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else { return }

            let frameCount = CMSampleBufferGetNumSamples(normalizedSampleBuffer)
            guard let presentationTime = nextPresentationTime(frameCount: frameCount) else { return }
            let didAppendOutput = mixer.receive(
                samples: samples,
                frameCount: frameCount,
                presentationTime: presentationTime,
                channelIndex: channelIndex,
                drivesOutput: drivesOutput
            )
            if drivesOutput, didAppendOutput {
                outputDriveState.notePrimaryOutputDriven()
            }
        } catch {
            return
        }
    }

    private func nextPresentationTime(frameCount: Int) -> CMTime? {
        lock.withLock {
            guard let anchor = timingAnchor.snapshot() else { return nil }
            if anchorGeneration != anchor.generation {
                guard let nextClock = try? AudioFramePTSClock(sampleRate: AudioSampleBufferNormalizer.sampleRate) else {
                    return nil
                }
                ptsClock = nextClock
                anchorGeneration = anchor.generation
            }
            return try? ptsClock.nextPresentationTime(
                anchorPresentationTime: anchor.presentationTime,
                frameCount: frameCount
            )
        }
    }
}

private final class ProgramAudioMonitorGeneratedSource: @unchecked Sendable {
    enum Mode {
        case silence
        case sweepSine
    }

    private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.ProgramAudioMonitorGeneratedSource")
    private let sink: ProgramAudioMonitorGeneratedSink
    private var timer: DispatchSourceTimer?

    init(
        channelIndex: Int32?,
        mixer: ProgramAudioMonitorMixer,
        mode: Mode,
        drivesOutput: Bool,
        timingAnchor: ProgramAudioMonitorTimingAnchor,
        outputDriveState: ProgramAudioMonitorOutputDriveState
    ) throws {
        sink = try ProgramAudioMonitorGeneratedSink(
            channelIndex: channelIndex,
            mixer: mixer,
            mode: mode,
            drivesOutput: drivesOutput,
            timingAnchor: timingAnchor,
            outputDriveState: outputDriveState
        )
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(Self.frameDurationNanoseconds),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [sink] in
            sink.render()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private static let frameDurationNanoseconds = max(
        1,
        1_000_000_000 * ProgramAudioMonitorGeneratedSink.frameCount / AudioSampleBufferNormalizer.sampleRate
    )
}

private final class ProgramAudioMonitorGeneratedSink: @unchecked Sendable {
    static let frameCount = 1_024

    private let lock = NSLock()
    private let channelIndex: Int32?
    private let mixer: ProgramAudioMonitorMixer
    private let mode: ProgramAudioMonitorGeneratedSource.Mode
    private let drivesOutput: Bool
    private let timingAnchor: ProgramAudioMonitorTimingAnchor
    private let outputDriveState: ProgramAudioMonitorOutputDriveState
    private var ptsClock: AudioFramePTSClock
    private var anchorGeneration: Int?
    private var phase: Float = 0
    private var amplitudePhase: Float = 0

    init(
        channelIndex: Int32?,
        mixer: ProgramAudioMonitorMixer,
        mode: ProgramAudioMonitorGeneratedSource.Mode,
        drivesOutput: Bool,
        timingAnchor: ProgramAudioMonitorTimingAnchor,
        outputDriveState: ProgramAudioMonitorOutputDriveState
    ) throws {
        self.channelIndex = channelIndex
        self.mixer = mixer
        self.mode = mode
        self.drivesOutput = drivesOutput
        self.timingAnchor = timingAnchor
        self.outputDriveState = outputDriveState
        ptsClock = try AudioFramePTSClock(sampleRate: AudioSampleBufferNormalizer.sampleRate)
    }

    func render() {
        if channelIndex == nil, outputDriveState.hasPrimaryOutputDriven {
            return
        }

        let frameCount = Self.frameCount
        guard let presentationTime = nextPresentationTime(frameCount: frameCount) else {
            return
        }
        guard let channelIndex else {
            mixer.render(frameCount: frameCount, presentationTime: presentationTime)
            return
        }

        let channelCount = AudioSampleBufferNormalizer.channelCount
        let phaseStep = 2 * Float.pi * 440 / Float(AudioSampleBufferNormalizer.sampleRate)
        let amplitude = switch mode {
        case .silence:
            Float(0)
        case .sweepSine:
            Float(0.08 + 0.35 * (0.5 + 0.5 * sin(amplitudePhase)))
        }
        amplitudePhase += 0.09
        if amplitudePhase > 2 * Float.pi {
            amplitudePhase -= 2 * Float.pi
        }

        var samples = [Float32](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            let sample = sin(phase) * amplitude
            phase += phaseStep
            if phase > 2 * Float.pi {
                phase -= 2 * Float.pi
            }

            let offset = frame * channelCount
            for channel in 0..<channelCount {
                samples[offset + channel] = sample
            }
        }

        let didAppendOutput = mixer.receive(
            samples: samples,
            frameCount: frameCount,
            presentationTime: presentationTime,
            channelIndex: channelIndex,
            drivesOutput: drivesOutput
        )
        if drivesOutput, didAppendOutput {
            outputDriveState.notePrimaryOutputDriven()
        }
    }

    private func nextPresentationTime(frameCount: Int) -> CMTime? {
        lock.withLock {
            guard let anchor = timingAnchor.snapshot() else { return nil }
            if anchorGeneration != anchor.generation {
                guard let nextClock = try? AudioFramePTSClock(sampleRate: AudioSampleBufferNormalizer.sampleRate) else {
                    return nil
                }
                ptsClock = nextClock
                anchorGeneration = anchor.generation
            }
            return try? ptsClock.nextPresentationTime(
                anchorPresentationTime: anchor.presentationTime,
                frameCount: frameCount
            )
        }
    }
}

private final class ProgramAudioMonitorMixer: @unchecked Sendable {
    private let lock = NSLock()
    private var audioEngine: LDTXAudioMixEngine
    private let channelCount: Int32
    private let output: ProgramAudioMonitorOutput
    private var timelinesByChannelIndex: [Int32: AudioChannelTimeline] = [:]

    init(
        audioEngine: LDTXAudioMixEngine,
        channelCount: Int32,
        output: ProgramAudioMonitorOutput
    ) throws {
        self.audioEngine = audioEngine
        self.channelCount = channelCount
        self.output = output
        for channelIndex in 0..<channelCount {
            timelinesByChannelIndex[channelIndex] = try AudioChannelTimeline(
                sampleRate: AudioSampleBufferNormalizer.sampleRate,
                channelCount: AudioSampleBufferNormalizer.channelCount
            )
        }
    }

    func receive(
        samples: [Float32],
        frameCount: Int,
        presentationTime: CMTime,
        channelIndex: Int32,
        drivesOutput: Bool
    ) -> Bool {
        let mixedSamples: [Float32]? = lock.withLock { () -> [Float32]? in
            guard let timeline = timelinesByChannelIndex[channelIndex] else {
                return nil
            }
            do {
                try timeline.insert(
                    samples: samples,
                    frameCount: frameCount,
                    presentationTime: presentationTime
                )
            } catch {
                return nil
            }
            guard drivesOutput else { return nil }
            return makeMixedSamples(
                frameCount: frameCount,
                readPresentationTime: presentationTime
            )
        }
        return append(mixedSamples, frameCount: frameCount, presentationTime: presentationTime)
    }

    func render(frameCount: Int, presentationTime: CMTime) {
        let mixedSamples: [Float32] = lock.withLock {
            makeMixedSamples(frameCount: frameCount, readPresentationTime: presentationTime)
        }
        _ = append(mixedSamples, frameCount: frameCount, presentationTime: presentationTime)
    }

    private func makeMixedSamples(
        frameCount: Int,
        readPresentationTime: CMTime
    ) -> [Float32] {
        let channelSampleCount = frameCount * AudioSampleBufferNormalizer.channelCount
        var mixedSamples = [Float32](repeating: 0, count: channelSampleCount)
        guard frameCount > 0 else { return mixedSamples }

        for channelIndex in 0..<channelCount {
            guard let timeline = timelinesByChannelIndex[channelIndex] else {
                continue
            }
            let sourceSamples: [Float32]
            do {
                sourceSamples = try timeline.read(
                    presentationTime: readPresentationTime,
                    frameCount: frameCount
                )
            } catch {
                continue
            }

            sourceSamples.withUnsafeBufferPointer { inputBuffer in
                mixedSamples.withUnsafeMutableBufferPointer { outputBuffer in
                    audioEngine.mixInterleavedFloat32(
                        channelIndex,
                        inputBuffer.baseAddress,
                        outputBuffer.baseAddress,
                        Int32(frameCount),
                        Int32(AudioSampleBufferNormalizer.channelCount),
                        false
                    )
                }
            }
        }
        return mixedSamples
    }

    private func append(_ samples: [Float32]?, frameCount: Int, presentationTime: CMTime) -> Bool {
        guard let samples,
              let sampleBuffer = ProgramAudioMonitorSampleBufferFactory.makeSampleBuffer(
                samples: samples,
                frameCount: frameCount,
                presentationTime: presentationTime,
                formatDescription: nil
              ) else {
            return false
        }
        return output.append(sampleBuffer)
    }
}

private final class ProgramAudioMonitorOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: SegmentedMP4Writer?
    private var lastPresentationTime: CMTime?

    func attach(writer: SegmentedMP4Writer) {
        lock.withLock {
            self.writer = writer
            lastPresentationTime = nil
        }
    }

    func detachWriter() {
        lock.withLock {
            writer = nil
            lastPresentationTime = nil
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let writer: SegmentedMP4Writer? = lock.withLock {
            let presentationTime = sampleBuffer.presentationTimeStamp
            guard presentationTime.isValid else {
                return nil
            }
            if let lastPresentationTime,
               CMTimeCompare(presentationTime, lastPresentationTime) <= 0 {
                return nil
            }
            lastPresentationTime = presentationTime
            return self.writer
        }
        writer?.append(sampleBuffer: sampleBuffer, kind: SegmentedMP4SampleKind.audio)
        return writer != nil
    }
}

private enum ProgramAudioMonitorSampleBufferFactory {
    static func makeSampleBuffer(
        samples: [Float32],
        frameCount: Int,
        presentationTime: CMTime,
        formatDescription providedFormatDescription: CMFormatDescription?
    ) -> CMSampleBuffer? {
        let byteCount = samples.count * MemoryLayout<Float32>.stride
        guard frameCount > 0, byteCount > 0 else {
            return nil
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }

        let replaceStatus = samples.withUnsafeBytes { buffer in
            CMBlockBufferReplaceDataBytes(
                with: buffer.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            return nil
        }

        let formatDescription: CMFormatDescription
        if let providedFormatDescription {
            formatDescription = providedFormatDescription
        } else if let generatedFormatDescription = makeAudioFormatDescription() {
            formatDescription = generatedFormatDescription
        } else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(AudioSampleBufferNormalizer.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr else {
            return nil
        }
        return sampleBuffer
    }

    private static func makeAudioFormatDescription() -> CMAudioFormatDescription? {
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: Float64(AudioSampleBufferNormalizer.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(AudioSampleBufferNormalizer.channelCount * MemoryLayout<Float32>.stride),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(AudioSampleBufferNormalizer.channelCount * MemoryLayout<Float32>.stride),
            mChannelsPerFrame: UInt32(AudioSampleBufferNormalizer.channelCount),
            mBitsPerChannel: UInt32(MemoryLayout<Float32>.stride * 8),
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr else {
            return nil
        }
        return formatDescription
    }
}
