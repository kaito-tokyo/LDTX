// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation

public enum AudioChannelTimelineError: Error, LocalizedError {
    case invalidConfiguration
    case invalidSampleBuffer
    case invalidPresentationTime

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The audio channel timeline configuration is invalid."
        case .invalidSampleBuffer:
            "The audio channel timeline sample buffer is invalid."
        case .invalidPresentationTime:
            "The audio channel timeline presentation time is invalid."
        }
    }
}

public final class AudioChannelTimeline: @unchecked Sendable {
    public let sampleRate: Int
    public let channelCount: Int
    public let capacityFrames: Int

    private var baseFrameIndex: Int64
    private var samples: [Float32]
    private var validFrames: [Bool]

    public init(
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        capacityFrames: Int = 48_000 * 5
    ) throws {
        guard sampleRate > 0, channelCount > 0, capacityFrames > 0 else {
            throw AudioChannelTimelineError.invalidConfiguration
        }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.capacityFrames = capacityFrames
        baseFrameIndex = 0
        samples = [Float32](repeating: 0, count: capacityFrames * channelCount)
        validFrames = [Bool](repeating: false, count: capacityFrames)
    }

    public func insert(
        samples sourceSamples: [Float32],
        frameCount: Int,
        presentationTime: CMTime
    ) throws {
        try sourceSamples.withUnsafeBufferPointer { sourceSamples in
            try insert(
                samples: sourceSamples,
                frameCount: frameCount,
                presentationTime: presentationTime
            )
        }
    }

    public func insert(
        samples sourceSamples: UnsafeBufferPointer<Float32>,
        frameCount: Int,
        presentationTime: CMTime
    ) throws {
        guard frameCount > 0,
              sourceSamples.count >= frameCount * channelCount else {
            throw AudioChannelTimelineError.invalidSampleBuffer
        }
        let startFrameIndex = try Self.frameIndex(
            for: presentationTime,
            sampleRate: sampleRate
        )
        insert(samples: sourceSamples, frameCount: frameCount, startFrameIndex: startFrameIndex)
    }

    public func read(
        presentationTime: CMTime,
        frameCount: Int
    ) throws -> [Float32] {
        guard frameCount > 0 else {
            return []
        }
        let startFrameIndex = try Self.frameIndex(
            for: presentationTime,
            sampleRate: sampleRate
        )
        return read(startFrameIndex: startFrameIndex, frameCount: frameCount)
    }

    public func hasCompleteRange(
        presentationTime: CMTime,
        frameCount: Int
    ) throws -> Bool {
        guard frameCount > 0 else {
            return true
        }
        let startFrameIndex = try Self.frameIndex(
            for: presentationTime,
            sampleRate: sampleRate
        )
        let endFrameIndex = startFrameIndex + Int64(frameCount)
        guard startFrameIndex >= baseFrameIndex,
              endFrameIndex <= baseFrameIndex + Int64(capacityFrames) else {
            return false
        }
        for frameOffset in 0..<frameCount {
            let frameIndex = startFrameIndex + Int64(frameOffset)
            guard validFrames[ringFrame(for: frameIndex)] else {
                return false
            }
        }
        return true
    }

    public static func frameIndex(
        for presentationTime: CMTime,
        sampleRate: Int = 48_000
    ) throws -> Int64 {
        guard sampleRate > 0 else {
            throw AudioChannelTimelineError.invalidConfiguration
        }
        guard presentationTime.isValid else {
            throw AudioChannelTimelineError.invalidPresentationTime
        }
        guard presentationTime.seconds.isFinite else {
            throw AudioChannelTimelineError.invalidPresentationTime
        }
        let scaledTime = CMTimeConvertScale(
            presentationTime,
            timescale: CMTimeScale(sampleRate),
            method: .roundHalfAwayFromZero
        )
        return scaledTime.value
    }

    public static func presentationTime(
        forFrameIndex frameIndex: Int64,
        sampleRate: Int = 48_000
    ) -> CMTime {
        CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(sampleRate))
    }

    private func insert(
        samples sourceSamples: UnsafeBufferPointer<Float32>,
        frameCount: Int,
        startFrameIndex: Int64
    ) {
        let endFrameIndex = startFrameIndex + Int64(frameCount)
        guard endFrameIndex > baseFrameIndex else {
            return
        }

        if endFrameIndex > baseFrameIndex + Int64(capacityFrames) {
            advanceBaseFrameIndex(endFrameIndex - Int64(capacityFrames))
        }

        let clippedStartFrameIndex = max(startFrameIndex, baseFrameIndex)
        let clippedEndFrameIndex = min(endFrameIndex, baseFrameIndex + Int64(capacityFrames))
        guard clippedStartFrameIndex < clippedEndFrameIndex else {
            return
        }

        let sourceStartFrameOffset = Int(clippedStartFrameIndex - startFrameIndex)
        let writableFrameCount = Int(clippedEndFrameIndex - clippedStartFrameIndex)

        for frameOffset in 0..<writableFrameCount {
            let timelineFrameIndex = clippedStartFrameIndex + Int64(frameOffset)
            let ringFrame = ringFrame(for: timelineFrameIndex)
            let sourceFrame = sourceStartFrameOffset + frameOffset
            let destinationSampleOffset = ringFrame * channelCount
            let sourceSampleOffset = sourceFrame * channelCount
            for channel in 0..<channelCount {
                samples[destinationSampleOffset + channel] = sourceSamples[sourceSampleOffset + channel]
            }
            validFrames[ringFrame] = true
        }
    }

    private func read(startFrameIndex: Int64, frameCount: Int) -> [Float32] {
        var output = [Float32](repeating: 0, count: frameCount * channelCount)
        for frameOffset in 0..<frameCount {
            let timelineFrameIndex = startFrameIndex + Int64(frameOffset)
            guard timelineFrameIndex >= baseFrameIndex,
                  timelineFrameIndex < baseFrameIndex + Int64(capacityFrames) else {
                continue
            }
            let ringFrame = ringFrame(for: timelineFrameIndex)
            guard validFrames[ringFrame] else {
                continue
            }
            let sourceSampleOffset = ringFrame * channelCount
            let destinationSampleOffset = frameOffset * channelCount
            for channel in 0..<channelCount {
                output[destinationSampleOffset + channel] = samples[sourceSampleOffset + channel]
            }
        }
        return output
    }

    private func advanceBaseFrameIndex(_ nextBaseFrameIndex: Int64) {
        guard nextBaseFrameIndex > baseFrameIndex else {
            return
        }
        let framesToInvalidate = min(Int(nextBaseFrameIndex - baseFrameIndex), capacityFrames)
        if framesToInvalidate == capacityFrames {
            validFrames = [Bool](repeating: false, count: capacityFrames)
        } else {
            for frameOffset in 0..<framesToInvalidate {
                let frameIndex = baseFrameIndex + Int64(frameOffset)
                validFrames[ringFrame(for: frameIndex)] = false
            }
        }
        baseFrameIndex = nextBaseFrameIndex
    }

    private func ringFrame(for frameIndex: Int64) -> Int {
        let capacity = Int64(capacityFrames)
        let remainder = frameIndex % capacity
        return Int(remainder >= 0 ? remainder : remainder + capacity)
    }
}
