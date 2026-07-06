// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Accelerate
import Combine
import CoreMedia
import Foundation
import LDTXCapture
import LDTXMP4
import OSLog

public struct InputAudioSpectrogramSnapshot: Sendable {
    public var columns: [[Float]]
    public var columnCapacity: Int
    public var binCount: Int
    public var sampleRate: Int
    public var analysisBandCount: Int

    public init(
        columns: [[Float]],
        columnCapacity: Int,
        binCount: Int,
        sampleRate: Int,
        analysisBandCount: Int
    ) {
        self.columns = columns
        self.columnCapacity = columnCapacity
        self.binCount = binCount
        self.sampleRate = sampleRate
        self.analysisBandCount = analysisBandCount
    }

    public static let empty = InputAudioSpectrogramSnapshot(
        columns: [],
        columnCapacity: 180,
        binCount: 96,
        sampleRate: AudioSampleBufferNormalizer.sampleRate,
        analysisBandCount: 128
    )
}

public final class InputAudioSpectrogramController: ObservableObject, @unchecked Sendable {
    fileprivate static let logger = Logger(
        subsystem: "tokyo.kaito.ldtx",
        category: "InputAudioSpectrogram"
    )

    @Published public private(set) var snapshot = InputAudioSpectrogramSnapshot.empty
    @Published public private(set) var statusText = "No audio selected"

    private let lock = NSLock()
    private var activeAudioDeviceID: String?
    private var captureService: CameraCaptureService?
    private var sessionID = 0

    public init() {}

    public func configure(audioDeviceID: String?) {
        var previousService: CameraCaptureService?
        var nextSessionID = 0
        lock.withLock {
            sessionID += 1
            nextSessionID = sessionID
            activeAudioDeviceID = audioDeviceID
            previousService = captureService
            captureService = nil
        }
        let startedSessionID = nextSessionID

        if let previousService {
            Task(priority: .utility) {
                await previousService.stop()
            }
        }

        guard let audioDeviceID else {
            Task { @MainActor [weak self] in
                self?.snapshot = .empty
                self?.statusText = "No audio selected"
            }
            return
        }

        let service = CameraCaptureService()
        lock.withLock {
            guard sessionID == startedSessionID else {
                return
            }
            captureService = service
        }

        Task { @MainActor [weak self] in
            self?.snapshot = .empty
            self?.statusText = "Starting audio preview..."
        }
        Self.logger.notice(
            "Configuring audio spectrogram preview: session=\(startedSessionID, privacy: .public), device=\(audioDeviceID, privacy: .public)"
        )

        Task(priority: .utility) { [weak self] in
            let analyzer: InputAudioSpectrogramAnalyzer
            do {
                analyzer = try InputAudioSpectrogramAnalyzer()
            } catch {
                guard let self else { return }
                guard self.isCurrent(sessionID: startedSessionID, audioDeviceID: audioDeviceID) else {
                    return
                }
                await MainActor.run {
                    self.snapshot = .empty
                    self.statusText = "Audio preview unavailable"
                }
                Self.logger.error(
                    "Audio spectrogram analyzer initialization failed: device=\(audioDeviceID, privacy: .public)"
                )
                return
            }

            do {
                try await service.startAudioCapture(audioDeviceID: audioDeviceID) { [weak self] sampleBuffer, kind in
                    self?.consume(
                        sampleBuffer,
                        kind: kind,
                        analyzer: analyzer,
                        sessionID: startedSessionID
                    )
                }

                guard let self else {
                    await service.stop()
                    return
                }
                guard self.isCurrent(sessionID: startedSessionID, audioDeviceID: audioDeviceID) else {
                    await service.stop()
                    return
                }
                await MainActor.run {
                    self.statusText = "48 kHz / 128-band DPSS PFB"
                }
                Self.logger.notice(
                    "Audio spectrogram capture started: session=\(startedSessionID, privacy: .public), device=\(audioDeviceID, privacy: .public)"
                )
            } catch {
                guard let self else { return }
                guard self.isCurrent(sessionID: startedSessionID, audioDeviceID: audioDeviceID) else {
                    return
                }
                await MainActor.run {
                    self.snapshot = .empty
                    self.statusText = "Audio preview unavailable"
                }
                Self.logger.error(
                    "Audio spectrogram capture failed: session=\(startedSessionID, privacy: .public), device=\(audioDeviceID, privacy: .public), error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    public func stop() {
        var previousService: CameraCaptureService?
        lock.withLock {
            sessionID += 1
            activeAudioDeviceID = nil
            previousService = captureService
            captureService = nil
        }
        if let previousService {
            Task(priority: .utility) {
                await previousService.stop()
            }
        }
    }

    private func consume(
        _ sampleBuffer: CMSampleBuffer,
        kind: CameraCaptureSampleKind,
        analyzer: InputAudioSpectrogramAnalyzer,
        sessionID: Int
    ) {
        guard kind == .audio,
              let snapshot = analyzer.append(sampleBuffer) else {
            return
        }
        guard isCurrent(sessionID: sessionID) else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                  self.isCurrent(sessionID: sessionID) else {
                return
            }
            self.snapshot = snapshot
        }
    }

    private func isCurrent(sessionID: Int, audioDeviceID: String? = nil) -> Bool {
        lock.withLock {
            guard self.sessionID == sessionID else {
                return false
            }
            if let audioDeviceID {
                return activeAudioDeviceID == audioDeviceID
            }
            return true
        }
    }
}

private final class InputAudioSpectrogramAnalyzer: @unchecked Sendable {
    private enum Constants {
        static let channelCount = 256
        static let analysisBandCount = channelCount / 2
        static let tapsPerChannel = 6
        static let prototypeLength = channelCount * tapsPerChannel
        static let analysisHopSamples = channelCount
        static let displayFrameDecimation = 4
        static let bandPowerLowPassAlpha: Float = 0.32
        static let binCount = 96
        static let columnCapacity = 180
        static let minimumDecibels: Float = -96
        static let maximumDecibels: Float = 0
        static let displayGainDecibels: Float = 30
        static let publishIntervalSeconds = 1.0 / 15.0
        static let minimumFrequency: Float = 32
        static let epsilon: Float = 0.000_000_1
        static let dftForward: Int32 = 1
        static let prototypeHalfBandwidth = 0.5 / Double(channelCount)
        static let dpssIterationCount = 18
    }

    private let normalizer: AudioSampleBufferNormalizer
    private let dftSetup: vDSP_DFT_Setup
    private let prototype: [Float]
    private let binRanges: [Range<Int>]
    private var analysisReal = [Float](repeating: 0, count: Constants.channelCount)
    private var analysisImag = [Float](repeating: 0, count: Constants.channelCount)
    private var pendingMonoSamples: [Float] = []
    private var outputReal = [Float](repeating: 0, count: Constants.channelCount)
    private var outputImag = [Float](repeating: 0, count: Constants.channelCount)
    private var filteredBandPowers = [Float](repeating: 0, count: Constants.analysisBandCount)
    private var hasInitializedBandPowerFilter = false
    private var analysisFramesSinceLastColumn = 0
    private var columns: [[Float]] = []
    private var lastPublishedAt = 0.0
    private var hasLoggedFirstNormalizedBuffer = false
    private var hasLoggedFirstColumn = false
    private var hasLoggedNormalizeFailure = false
    private static let sharedPrototype = makeDPSSPrototype(
        length: Constants.prototypeLength,
        halfBandwidth: Constants.prototypeHalfBandwidth,
        iterationCount: Constants.dpssIterationCount
    )
    private static let sharedBinRanges = makeBinRanges()

    init() throws {
        normalizer = try AudioSampleBufferNormalizer()
        guard let dftSetup = vDSP_DFT_zrop_CreateSetup(
            nil,
            vDSP_Length(Constants.channelCount),
            vDSP_DFT_Direction(rawValue: Constants.dftForward)!
        ) else {
            throw InputAudioSpectrogramAnalyzerError.fftSetupFailed
        }
        self.dftSetup = dftSetup

        prototype = Self.sharedPrototype
        binRanges = Self.sharedBinRanges
    }

    deinit {
        vDSP_DFT_DestroySetup(dftSetup)
    }

    func append(_ sampleBuffer: CMSampleBuffer) -> InputAudioSpectrogramSnapshot? {
        do {
            guard let normalizedSampleBuffer = try normalizer.normalize(sampleBuffer),
                  let dataBuffer = CMSampleBufferGetDataBuffer(normalizedSampleBuffer) else {
                if !hasLoggedNormalizeFailure {
                    hasLoggedNormalizeFailure = true
                    InputAudioSpectrogramController.logger.error(
                        "Audio spectrogram normalization produced no output buffer"
                    )
                }
                return nil
            }
            if !hasLoggedFirstNormalizedBuffer {
                hasLoggedFirstNormalizedBuffer = true
                InputAudioSpectrogramController.logger.notice(
                    "Audio spectrogram received first normalized buffer: pts=\(normalizedSampleBuffer.presentationTimeStamp.seconds, privacy: .public), samples=\(CMSampleBufferGetNumSamples(normalizedSampleBuffer), privacy: .public)"
                )
            }

            let byteCount = CMBlockBufferGetDataLength(dataBuffer)
            guard byteCount > 0 else { return nil }

            var samples = [Float32](repeating: 0, count: byteCount / MemoryLayout<Float32>.stride)
            let copyStatus = samples.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(
                    dataBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: buffer.baseAddress!
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else {
                return nil
            }

            appendMonoSamples(fromInterleavedStereoSamples: samples)

            var renderedColumn = false
            while pendingMonoSamples.count >= Constants.prototypeLength {
                updateFilteredBandPowers()
                analysisFramesSinceLastColumn += 1
                if analysisFramesSinceLastColumn == Constants.displayFrameDecimation {
                    columns.append(makeSpectrumColumn(fromBandPowers: filteredBandPowers))
                    if columns.count > Constants.columnCapacity {
                        columns.removeFirst(columns.count - Constants.columnCapacity)
                    }
                    analysisFramesSinceLastColumn = 0
                    renderedColumn = true
                    if !hasLoggedFirstColumn {
                        hasLoggedFirstColumn = true
                        InputAudioSpectrogramController.logger.notice(
                            "Audio spectrogram rendered first column"
                        )
                    }
                }
                pendingMonoSamples.removeFirst(Constants.analysisHopSamples)
            }

            let now = ProcessInfo.processInfo.systemUptime
            guard renderedColumn,
                  now - lastPublishedAt >= Constants.publishIntervalSeconds else {
                return nil
            }

            lastPublishedAt = now
            return InputAudioSpectrogramSnapshot(
                columns: columns,
                columnCapacity: Constants.columnCapacity,
                binCount: Constants.binCount,
                sampleRate: AudioSampleBufferNormalizer.sampleRate,
                analysisBandCount: Constants.analysisBandCount
            )
        } catch {
            if !hasLoggedNormalizeFailure {
                hasLoggedNormalizeFailure = true
                InputAudioSpectrogramController.logger.error(
                    "Audio spectrogram append failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            return nil
        }
    }

    private func appendMonoSamples(fromInterleavedStereoSamples samples: [Float32]) {
        pendingMonoSamples.reserveCapacity(pendingMonoSamples.count + (samples.count / 2))
        for index in stride(from: 0, to: samples.count - 1, by: 2) {
            pendingMonoSamples.append((samples[index] + samples[index + 1]) * 0.5)
        }
    }

    private func updateFilteredBandPowers() {
        let phaseVector = makePhaseVector()
        for index in 0..<Constants.channelCount {
            analysisReal[index] = phaseVector[index]
            analysisImag[index] = 0
        }

        vDSP_DFT_Execute(
            dftSetup,
            &analysisReal,
            &analysisImag,
            &outputReal,
            &outputImag
        )

        let bandPowers = makeBandPowers()
        if !hasInitializedBandPowerFilter {
            filteredBandPowers = bandPowers
            hasInitializedBandPowerFilter = true
        } else {
            let alpha = Constants.bandPowerLowPassAlpha
            let beta = 1 - alpha
            for index in 0..<Constants.analysisBandCount {
                filteredBandPowers[index] = beta * filteredBandPowers[index] + alpha * bandPowers[index]
            }
        }
    }

    private func makeSpectrumColumn(fromBandPowers bandPowers: [Float]) -> [Float] {
        var column = [Float](repeating: 0, count: Constants.binCount)
        for (binIndex, range) in binRanges.enumerated() {
            var accumulatedPower: Float = 0
            for bandIndex in range {
                accumulatedPower += bandPowers[bandIndex]
            }
            let meanPower = accumulatedPower / Float(max(range.count, 1))
            let magnitude = sqrt(meanPower) / Float(Constants.channelCount)
            let decibels = 20 * log10(max(magnitude, Constants.epsilon)) + Constants.displayGainDecibels
            let normalized = min(
                max(
                    (decibels - Constants.minimumDecibels) /
                        (Constants.maximumDecibels - Constants.minimumDecibels),
                    0
                ),
                1
            )
            column[binIndex] = pow(normalized, 0.75)
        }
        return column
    }

    private func makePhaseVector() -> [Float] {
        let windowStart = pendingMonoSamples.count - Constants.prototypeLength
        var phases = [Float](repeating: 0, count: Constants.channelCount)
        for phaseIndex in 0..<Constants.channelCount {
            var sampleIndex = windowStart + phaseIndex
            var prototypeIndex = phaseIndex
            var accumulated: Float = 0
            for _ in 0..<Constants.tapsPerChannel {
                accumulated += pendingMonoSamples[sampleIndex] * prototype[prototypeIndex]
                sampleIndex += Constants.channelCount
                prototypeIndex += Constants.channelCount
            }
            phases[phaseIndex] = accumulated
        }
        return phases
    }

    private func makeBandPowers() -> [Float] {
        var powers = [Float](repeating: 0, count: Constants.analysisBandCount)
        for bandIndex in 0..<Constants.analysisBandCount {
            let fftIndex = bandIndex + 1
            powers[bandIndex] = outputReal[fftIndex] * outputReal[fftIndex] +
                outputImag[fftIndex] * outputImag[fftIndex]
        }
        return powers
    }

    private static func makeBinRanges() -> [Range<Int>] {
        let nyquist = Float(AudioSampleBufferNormalizer.sampleRate) * 0.5
        let logMin = log(Constants.minimumFrequency)
        let logMax = log(nyquist)
        return (0..<Constants.binCount).map { binIndex in
            let startUnit = Float(binIndex) / Float(Constants.binCount)
            let endUnit = Float(binIndex + 1) / Float(Constants.binCount)
            let startFrequency = exp(logMin + (logMax - logMin) * startUnit)
            let endFrequency = exp(logMin + (logMax - logMin) * endUnit)
            let startIndex = max(
                Int(startFrequency / nyquist * Float(Constants.analysisBandCount)),
                1
            ) - 1
            let endIndex = min(
                max(Int(endFrequency / nyquist * Float(Constants.analysisBandCount)), startIndex + 2),
                Constants.analysisBandCount
            )
            return startIndex..<endIndex
        }
    }

    private static func makeDPSSPrototype(
        length: Int,
        halfBandwidth: Double,
        iterationCount: Int
    ) -> [Float] {
        let diagonalValue = 2 * halfBandwidth
        let kernel = (0..<length).map { offset -> Double in
            guard offset > 0 else {
                return diagonalValue
            }
            let x = 2 * Double.pi * halfBandwidth * Double(offset)
            return sin(x) / (Double.pi * Double(offset))
        }

        var vector = [Double](repeating: 1.0 / sqrt(Double(length)), count: length)
        var next = [Double](repeating: 0, count: length)

        for _ in 0..<iterationCount {
            for index in 0..<length {
                var value = 0.0
                for sourceIndex in 0..<length {
                    value += kernel[abs(index - sourceIndex)] * vector[sourceIndex]
                }
                next[index] = value
            }

            symmetrize(&next)

            let norm = sqrt(next.reduce(0.0) { partial, value in
                partial + value * value
            })
            guard norm > 0 else {
                break
            }
            for index in 0..<length {
                next[index] /= norm
            }
            swap(&vector, &next)
        }

        return vector.map(Float.init)
    }

    private static func symmetrize(_ values: inout [Double]) {
        var left = 0
        var right = values.count - 1
        while left < right {
            let average = (values[left] + values[right]) * 0.5
            values[left] = average
            values[right] = average
            left += 1
            right -= 1
        }
    }
}

private enum InputAudioSpectrogramAnalyzerError: Error {
    case fftSetupFailed
}
