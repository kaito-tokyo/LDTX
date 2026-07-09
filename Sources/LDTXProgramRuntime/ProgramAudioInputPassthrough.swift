// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import Foundation

final class ProgramAudioInputPassthrough: @unchecked Sendable {
    private let lock = NSLock()
    private var channelStatesByKey: [String: ProgramAudioInputPassthroughChannelState] = [:]

    func configure(channelKeys: [String]) {
        lock.withLock {
            resetLocked()
            for channelKey in Set(channelKeys).sorted() {
                channelStatesByKey[channelKey] = ProgramAudioInputPassthroughChannelState()
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

private final class ProgramAudioInputPassthroughChannelState: @unchecked Sendable {
    private let queueLock = NSLock()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playbackFormat: AVAudioFormat?
    private var queuedFrameCount = 0
    private var isEngineConfigured = false

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        do {
            guard let playbackBuffer = try playbackBuffer(from: sampleBuffer) else {
                return
            }
            try configureEngineIfNeeded(format: playbackBuffer.format)
            trimIfNeeded(incomingFrameCount: Int(playbackBuffer.frameLength))
            schedule(playbackBuffer)
        } catch {
            reset()
        }
    }

    func stop() {
        reset()
        if isEngineConfigured {
            engine.detach(player)
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
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        playbackFormat = format
        isEngineConfigured = true
    }

    private func playbackBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }
        guard let formatDescription = sampleBuffer.formatDescription else {
            throw ProgramAudioInputPassthroughError.missingFormatDescription
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw ProgramAudioInputPassthroughError.bufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            throw ProgramAudioInputPassthroughError.pcmCopyFailed(copyStatus)
        }
        return buffer
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

    private static let maxQueuedFrames = 4_096
}

private enum ProgramAudioInputPassthroughError: Error {
    case missingFormatDescription
    case bufferAllocationFailed
    case pcmCopyFailed(OSStatus)
}
