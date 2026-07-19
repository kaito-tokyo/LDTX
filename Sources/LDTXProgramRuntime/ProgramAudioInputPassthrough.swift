// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import OSLog

private let programAudioInputPassthroughLogger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "ProgramAudioInputPassthrough"
)

final class ProgramAudioInputPassthrough: @unchecked Sendable {
    private let lock = NSLock()
    private var channelStatesByKey: [String: ProgramAudioInputPassthroughChannelState] = [:]

    func configure(channelGainsByKey: [String: Float]) {
        let channelKeys = channelGainsByKey.keys.sorted()
        programAudioInputPassthroughLogger.notice(
            "Configuring input audio passthrough channelCount=\(channelKeys.count, privacy: .public) channelKeys=\(channelKeys.joined(separator: ","), privacy: .public)"
        )
        lock.withLock {
            resetLocked()
            for channelKey in channelKeys {
                channelStatesByKey[channelKey] = ProgramAudioInputPassthroughChannelState(
                    channelKey: channelKey,
                    linearGain: channelGainsByKey[channelKey] ?? 1
                )
            }
        }
    }

    func updateGains(_ gainsByKey: [String: Float]) {
        lock.withLock {
            for (channelKey, gain) in gainsByKey {
                channelStatesByKey[channelKey]?.setGain(linearGain: gain)
            }
        }
    }

    func stop() {
        lock.withLock {
            resetLocked()
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, for channelKey: String) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        lock.withLock {
            guard let state = channelStatesByKey[channelKey] else {
                return
            }
            state.enqueue(sampleBuffer)
        }
    }

    private func resetLocked() {
        for state in channelStatesByKey.values {
            state.stop()
        }
        channelStatesByKey = [:]
    }
}

final class ProgramAudioInputPassthroughChannelState: @unchecked Sendable {
    private let channelKey: String
    private let queueLock = NSLock()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let gainUnit = AVAudioUnitEQ(numberOfBands: 1)
    private var playbackFormat: AVAudioFormat?
    private var queuedFrameCount = 0
    private var isEngineConfigured = false
    private var receivedBufferCount = 0

    init(channelKey: String = "unknown", linearGain: Float) {
        self.channelKey = channelKey
        gainUnit.bands.first?.bypass = true
        setGain(linearGain: linearGain)
    }

    var gainDecibels: Float {
        gainUnit.globalGain
    }

    func setGain(linearGain: Float) {
        gainUnit.globalGain = Self.decibels(fromLinearGain: linearGain)
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        receivedBufferCount += 1
        if receivedBufferCount == 1 {
            programAudioInputPassthroughLogger.notice(
                "Input audio passthrough received first buffer channelKey=\(self.channelKey, privacy: .public) sampleCount=\(CMSampleBufferGetNumSamples(sampleBuffer), privacy: .public)"
            )
        }
        do {
            guard let playbackBuffer = try playbackBuffer(from: sampleBuffer) else {
                return
            }
            try configureEngineIfNeeded(format: playbackBuffer.format)
            trimIfNeeded(incomingFrameCount: Int(playbackBuffer.frameLength))
            schedule(playbackBuffer)
        } catch {
            let nsError = error as NSError
            programAudioInputPassthroughLogger.error(
                "Input audio passthrough failed channelKey=\(self.channelKey, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)"
            )
            reset()
        }
    }

    func stop() {
        reset()
        if isEngineConfigured {
            engine.detach(player)
            engine.detach(gainUnit)
            isEngineConfigured = false
        }
        playbackFormat = nil
    }

    private func configureEngineIfNeeded(format: AVAudioFormat) throws {
        if isEngineConfigured,
           let playbackFormat,
           Self.isSamePlaybackFormat(playbackFormat, format) {
            if !engine.isRunning {
                try engine.start()
            }
            return
        }

        reset()
        if isEngineConfigured {
            engine.detach(player)
            engine.detach(gainUnit)
        }

        engine.attach(player)
        engine.attach(gainUnit)
        engine.connect(player, to: gainUnit, format: format)
        engine.connect(gainUnit, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        programAudioInputPassthroughLogger.notice(
            "Input audio passthrough engine started channelKey=\(self.channelKey, privacy: .public) sampleRate=\(format.sampleRate, privacy: .public) channelCount=\(format.channelCount, privacy: .public) interleaved=\(format.isInterleaved, privacy: .public)"
        )
        playbackFormat = format
        isEngineConfigured = true
    }

    private func playbackBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }
        guard let formatDescription = sampleBuffer.formatDescription else {
            throw ProgramAudioInputPassthroughError.missingFormatDescription
        }
        let captureFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        guard let captureBuffer = AVAudioPCMBuffer(
            pcmFormat: captureFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw ProgramAudioInputPassthroughError.bufferAllocationFailed
        }
        captureBuffer.frameLength = AVAudioFrameCount(frameCount)

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: captureBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            throw ProgramAudioInputPassthroughError.pcmCopyFailed(copyStatus)
        }

        let playbackFormat = try Self.playbackFormat(for: captureFormat)
        guard !Self.isSamePlaybackFormat(captureFormat, playbackFormat) else {
            return captureBuffer
        }
        return try Self.convert(captureBuffer, to: playbackFormat)
    }

    private func trimIfNeeded(incomingFrameCount: Int) {
        let shouldTrim = queueLock.withLock {
            queuedFrameCount + incomingFrameCount > Self.maxQueuedFrames
        }
        if !shouldTrim {
            return
        }
        resetQueue()
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        queueLock.withLock {
            queuedFrameCount += frameCount
        }
        player.scheduleBuffer(buffer) { [weak self] in
            self?.noteFinished(frameCount: frameCount)
        }
        if !engine.isRunning {
            try? engine.start()
        }
        if !player.isPlaying {
            player.play()
        }
    }

    private func noteFinished(frameCount: Int) {
        queueLock.withLock {
            queuedFrameCount = max(0, queuedFrameCount - frameCount)
        }
    }

    private func reset() {
        player.stop()
        if engine.isRunning {
            engine.pause()
        }
        queueLock.withLock {
            queuedFrameCount = 0
        }
    }

    private func resetQueue() {
        player.stop()
        queueLock.withLock {
            queuedFrameCount = 0
        }
    }

    private static func isSamePlaybackFormat(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private static func decibels(fromLinearGain gain: Float) -> Float {
        guard gain.isFinite, gain > 0 else {
            return -80
        }
        return min(max(20 * log10(gain), -80), 20)
    }

    private static func playbackFormat(for captureFormat: AVAudioFormat) throws -> AVAudioFormat {
        guard captureFormat.sampleRate > 0, captureFormat.channelCount > 0,
              let playbackFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: captureFormat.sampleRate,
                channels: captureFormat.channelCount,
                interleaved: false
              ) else {
            throw ProgramAudioInputPassthroughError.unsupportedInputFormat
        }
        return playbackFormat
    }

    private static func convert(
        _ inputBuffer: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat) else {
            throw ProgramAudioInputPassthroughError.unsupportedInputFormat
        }
        let outputCapacity = AVAudioFrameCount(
            max(
                1,
                Int(ceil(Double(inputBuffer.frameLength) * outputFormat.sampleRate / inputBuffer.format.sampleRate)) + 256
            )
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw ProgramAudioInputPassthroughError.bufferAllocationFailed
        }

        final class SingleInputProvider: @unchecked Sendable {
            private var inputBuffer: AVAudioPCMBuffer?

            init(inputBuffer: AVAudioPCMBuffer) {
                self.inputBuffer = inputBuffer
            }

            func provide(inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
                guard let inputBuffer else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                self.inputBuffer = nil
                inputStatus.pointee = .haveData
                return inputBuffer
            }
        }

        let inputProvider = SingleInputProvider(inputBuffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            inputProvider.provide(inputStatus: inputStatus)
        }
        if status == .error {
            throw ProgramAudioInputPassthroughError.conversionFailed(
                conversionError?.localizedDescription ?? "Unknown converter error"
            )
        }
        guard outputBuffer.frameLength > 0 else {
            return nil
        }
        return outputBuffer
    }

    private static let maxQueuedFrames = 4_096
}

private enum ProgramAudioInputPassthroughError: Error {
    case missingFormatDescription
    case unsupportedInputFormat
    case bufferAllocationFailed
    case pcmCopyFailed(OSStatus)
    case conversionFailed(String)
}
