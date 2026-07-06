// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public enum FileMP4WriterError: Error, LocalizedError {
    case invalidConfiguration
    case cannotAddVideoInput
    case cannotAddAudioInput
    case preflightFailed(String)
    case startWritingFailed(String)
    case writerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The MP4 writer configuration is invalid."
        case .cannotAddVideoInput:
            "The video input could not be added to the MP4 writer."
        case .cannotAddAudioInput:
            "The audio input could not be added to the MP4 writer."
        case let .preflightFailed(reason):
            "The MP4 writer preflight failed: \(reason)"
        case let .startWritingFailed(reason):
            "The MP4 writer could not start writing: \(reason)"
        case let .writerFailed(reason):
            "The MP4 writer failed: \(reason)"
        }
    }
}

public final class FileMP4Writer: @unchecked Sendable {
    private let assetWriter: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let videoReceiver: AVAssetWriterInput.SampleBufferReceiver
    private let audioReceiver: AVAssetWriterInput.SampleBufferReceiver?

    private var sourceStartTime: CMTime?
    private var hasStartedSession = false
    private var appendFailureDescription: String?

    public init(
        outputURL: URL,
        configuration: SegmentedMP4WriterConfiguration,
        includesAudio: Bool = true
    ) throws {
        guard configuration.width > 0,
              configuration.height > 0,
              configuration.frameRate > 0,
              configuration.videoBitRate > 0,
              configuration.audioSampleRate > 0,
              configuration.audioChannelCount > 0,
              configuration.audioBitRate > 0,
              configuration.timescale > 0 else {
            throw FileMP4WriterError.invalidConfiguration
        }

        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        assetWriter.movieTimeScale = CMTimeScale(configuration.timescale)

        let videoOutputSettings = Self.videoOutputSettings(configuration: configuration)
        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoOutputSettings
        )
        videoInput.expectsMediaDataInRealTime = true

        let audioOutputSettings: [String: Any]?
        if includesAudio {
            audioOutputSettings = Self.audioOutputSettings(configuration: configuration)
            audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: audioOutputSettings
            )
            audioInput?.expectsMediaDataInRealTime = true
        } else {
            audioOutputSettings = nil
            audioInput = nil
        }

        try Self.preflight(
            assetWriter: assetWriter,
            videoOutputSettings: videoOutputSettings,
            audioOutputSettings: audioOutputSettings
        )

        guard assetWriter.canAdd(videoInput) else {
            throw FileMP4WriterError.cannotAddVideoInput
        }
        videoReceiver = assetWriter.inputReceiver(for: videoInput)

        if let audioInput {
            guard assetWriter.canAdd(audioInput) else {
                throw FileMP4WriterError.cannotAddAudioInput
            }
            audioReceiver = assetWriter.inputReceiver(for: audioInput)
        } else {
            audioReceiver = nil
        }

        do {
            try assetWriter.start()
        } catch {
            throw FileMP4WriterError.startWritingFailed(
                assetWriter.error?.localizedDescription ?? error.localizedDescription
            )
        }
    }

    public func append(sampleBuffer: consuming CMSampleBuffer, kind: SegmentedMP4SampleKind) {
        guard CMSampleBufferDataIsReady(sampleBuffer), assetWriter.status == .writing else {
            return
        }

        switch kind {
        case .video:
            appendVideo(consume sampleBuffer)
        case .audio:
            appendAudio(consume sampleBuffer)
        }
    }

    public func finish() async throws {
        guard assetWriter.status == .writing || assetWriter.status == .unknown else {
            if assetWriter.status == .failed {
                throw FileMP4WriterError.writerFailed(
                    assetWriter.error?.localizedDescription ?? appendFailureDescription ?? "Unknown error"
                )
            }
            return
        }

        videoReceiver.finish()
        audioReceiver?.finish()

        await assetWriter.finishWriting()

        if assetWriter.status == .failed {
            throw FileMP4WriterError.writerFailed(
                assetWriter.error?.localizedDescription ?? appendFailureDescription ?? "Unknown error"
            )
        }
    }

    private func appendVideo(_ sampleBuffer: consuming CMSampleBuffer) {
        let sourcePresentationTime = sampleBuffer.presentationTimeStamp
        guard sourcePresentationTime.isValid else { return }

        if sourceStartTime == nil {
            sourceStartTime = sourcePresentationTime
        }
        guard let sourceStartTime else { return }

        startSessionIfNeeded(at: sourceStartTime)
        append(consume sampleBuffer, to: videoReceiver)
    }

    private func appendAudio(_ sampleBuffer: consuming CMSampleBuffer) {
        guard let sourceStartTime else { return }
        let sourcePresentationTime = sampleBuffer.presentationTimeStamp
        guard sourcePresentationTime.isValid, sourcePresentationTime >= sourceStartTime else { return }
        guard let audioReceiver else { return }

        startSessionIfNeeded(at: sourceStartTime)
        append(consume sampleBuffer, to: audioReceiver)
    }

    private func append(
        _ sampleBuffer: consuming CMSampleBuffer,
        to receiver: AVAssetWriterInput.SampleBufferReceiver
    ) {
        do {
            nonisolated(unsafe) let unsafeSampleBuffer = sampleBuffer
            let readySampleBuffer = CMReadySampleBuffer(unsafeBuffer: unsafeSampleBuffer)
            _ = try receiver.appendImmediately(readySampleBuffer)
        } catch {
            appendFailureDescription = error.localizedDescription
        }
    }

    private func startSessionIfNeeded(at presentationTimeStamp: CMTime) {
        guard !hasStartedSession else { return }
        assetWriter.startSession(atSourceTime: presentationTimeStamp)
        hasStartedSession = true
    }

    private static func preflight(
        assetWriter: AVAssetWriter,
        videoOutputSettings: [String: Any],
        audioOutputSettings: [String: Any]?
    ) throws {
        guard assetWriter.availableMediaTypes.contains(.video) else {
            throw FileMP4WriterError.preflightFailed(
                "video is not in availableMediaTypes=\(mediaTypesDescription(assetWriter.availableMediaTypes))"
            )
        }
        guard assetWriter.canApply(outputSettings: videoOutputSettings, forMediaType: .video) else {
            throw FileMP4WriterError.preflightFailed(
                "canApply(outputSettings:) failed for video; availableMediaTypes=\(mediaTypesDescription(assetWriter.availableMediaTypes))"
            )
        }

        if let audioOutputSettings {
            guard assetWriter.availableMediaTypes.contains(.audio) else {
                throw FileMP4WriterError.preflightFailed(
                    "audio is not in availableMediaTypes=\(mediaTypesDescription(assetWriter.availableMediaTypes))"
                )
            }
            guard assetWriter.canApply(outputSettings: audioOutputSettings, forMediaType: .audio) else {
                throw FileMP4WriterError.preflightFailed(
                    "canApply(outputSettings:) failed for audio; availableMediaTypes=\(mediaTypesDescription(assetWriter.availableMediaTypes))"
                )
            }
        }
    }

    private static func mediaTypesDescription(_ mediaTypes: [AVMediaType]) -> String {
        "[" + mediaTypes.map(\.rawValue).joined(separator: ",") + "]"
    }

    private static func videoOutputSettings(configuration: SegmentedMP4WriterConfiguration) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: configuration.videoBitRate,
                AVVideoExpectedSourceFrameRateKey: configuration.frameRate,
                AVVideoMaxKeyFrameIntervalKey: configuration.frameRate * configuration.segmentDurationSeconds,
                AVVideoMaxKeyFrameIntervalDurationKey: Double(configuration.segmentDurationSeconds),
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
    }

    private static func audioOutputSettings(configuration: SegmentedMP4WriterConfiguration) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: configuration.audioSampleRate,
            AVNumberOfChannelsKey: configuration.audioChannelCount,
            AVEncoderBitRateKey: configuration.audioBitRate
        ]
    }
}
