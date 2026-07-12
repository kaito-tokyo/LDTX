// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import OSLog
import os

public struct SegmentedMP4WriterConfiguration: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var videoBitRate: Int
    public var videoPixelBufferPoolMinimumBufferCount: Int
    public var audioSampleRate: Int
    public var audioChannelCount: Int
    public var audioBitRate: Int
    public var segmentDurationSeconds: Int
    public var timescale: Int
    public var startNumber: Int

    public init(
        width: Int,
        height: Int,
        frameRate: Int,
        videoBitRate: Int,
        videoPixelBufferPoolMinimumBufferCount: Int = 24,
        audioSampleRate: Int = 48_000,
        audioChannelCount: Int = 2,
        audioBitRate: Int = 128_000,
        segmentDurationSeconds: Int = 2,
        timescale: Int = 1_000,
        startNumber: Int = 1
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoBitRate = videoBitRate
        self.videoPixelBufferPoolMinimumBufferCount = videoPixelBufferPoolMinimumBufferCount
        self.audioSampleRate = audioSampleRate
        self.audioChannelCount = audioChannelCount
        self.audioBitRate = audioBitRate
        self.segmentDurationSeconds = segmentDurationSeconds
        self.timescale = timescale
        self.startNumber = startNumber
    }
}

public enum SegmentedMP4SampleKind: Equatable, Sendable {
    case video
    case audio
}

public enum SegmentedMP4WriterError: Error, LocalizedError {
    case invalidConfiguration
    case cannotAddVideoInput
    case cannotAddAudioInput
    case preflightFailed(String)
    case startWritingFailed(String)
    case writerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The segmented MP4 writer configuration is invalid."
        case .cannotAddVideoInput:
            "The video input could not be added to the segmented MP4 writer."
        case .cannotAddAudioInput:
            "The audio input could not be added to the segmented MP4 writer."
        case let .preflightFailed(reason):
            "The segmented MP4 writer preflight failed: \(reason)"
        case let .startWritingFailed(reason):
            "The segmented MP4 writer could not start writing: \(reason)"
        case let .writerFailed(reason):
            "The segmented MP4 writer failed: \(reason)"
        }
    }
}

public final class SegmentedMP4Writer: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    public typealias SegmentHandler = @Sendable (SegmentedMP4Segment) -> Void

    private static let logger = Logger(
        subsystem: "tokyo.kaito.ldtx",
        category: "SegmentedMP4Writer"
    )
    private static let signpostLog = OSLog(subsystem: "tokyo.kaito.ldtx", category: "PointsOfInterest")

    private let assetWriter: AVAssetWriter
    private let configuration: SegmentedMP4WriterConfiguration
    private let videoPixelBufferNormalizer: VideoPixelBufferNormalizer
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var videoPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let diagnostics: String
    private let outputTimescale: CMTimeScale
    private let writerQueue = DispatchQueue(label: "tokyo.kaito.ldtx.SegmentedMP4Writer")
    private let writerQueueKey = DispatchSpecificKey<Void>()
    private let inboundMediaLock = NSLock()
    private var inboundMedia: [InboundMedia] = []
    private let onSegment: SegmentHandler

    private var hasStartedSession = false
    private var pendingVideoFormatDescription: CMFormatDescription?
    private var pendingAudioFormatDescription: CMFormatDescription?
    private var pendingVideoPixelBuffers: [PendingVideoPixelBuffer] = []
    private var pendingAudioSampleBuffers: [CMSampleBuffer] = []
    private var isFinishing = false
    private var pendingFinishHandler: (@Sendable (Result<Void, any Error>) -> Void)?
    private var appendFailureDescription: String?
    private var encodedVideoFrameCount = 0
    private var appendedVideoFrameCount = 0
    private var appendedAudioBufferCount = 0
    private var initializationSegmentCount = 0
    private var mediaSegmentCount = 0
    private var inputVideoSampleCount = 0
    private var inputAudioSampleCount = 0
    private var waitedVideoReceiverFrameCount = 0
    private var waitedAudioReceiverBufferCount = 0
    private var droppedNonMonotonicVideoFrameCount = 0
    private var droppedPreRollAudioBufferCount = 0
    private var firstInputVideoDescription: String?
    private var firstInputAudioDescription: String?
    private var firstSourceVideoPresentationTime: CMTime?
    private var firstSourceAudioPresentationTime: CMTime?
    private var lastAcceptedVideoPresentationTime: CMTime?
    private var nextSegmentNumber: Int

    public init(configuration: SegmentedMP4WriterConfiguration, onSegment: @escaping SegmentHandler) throws {
        guard configuration.width > 0,
              configuration.height > 0,
              configuration.frameRate > 0,
              configuration.videoBitRate > 0,
              configuration.videoPixelBufferPoolMinimumBufferCount > 0,
              configuration.audioSampleRate > 0,
              configuration.audioChannelCount > 0,
              configuration.audioBitRate > 0,
              configuration.segmentDurationSeconds > 0,
              configuration.timescale > 0,
              configuration.startNumber > 0 else {
            throw SegmentedMP4WriterError.invalidConfiguration
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LDTX-SegmentedMP4", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        outputTimescale = CMTimeScale(configuration.frameRate)
        self.configuration = configuration
        videoPixelBufferNormalizer = try VideoPixelBufferNormalizer(
            width: configuration.width,
            height: configuration.height,
            minimumBufferCount: configuration.videoPixelBufferPoolMinimumBufferCount
        )

        assetWriter = AVAssetWriter(contentType: .mpeg4Movie)
        assetWriter.directoryForTemporaryFiles = temporaryDirectory
        assetWriter.movieTimeScale = outputTimescale
        assetWriter.outputFileTypeProfile = .mpeg4AppleHLS
        assetWriter.preferredOutputSegmentInterval = CMTime(
            seconds: Double(configuration.segmentDurationSeconds),
            preferredTimescale: outputTimescale
        )

        try Self.preflight(
            assetWriter: assetWriter,
            configuration: configuration,
            requiredMediaTypes: [.video, .audio]
        )

        diagnostics = Self.diagnostics(
            configuration: configuration,
            temporaryDirectory: temporaryDirectory,
            assetWriter: assetWriter
        )

        self.onSegment = onSegment
        nextSegmentNumber = configuration.startNumber

        super.init()

        writerQueue.setSpecific(key: writerQueueKey, value: ())
        assetWriter.delegate = self
    }

    public func append(sampleBuffer: CMSampleBuffer, kind: SegmentedMP4SampleKind) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        inboundMediaLock.withLock {
            inboundMedia.append(.sampleBuffer(sampleBuffer, kind))
        }
        writerQueue.async { [weak self] in
            self?.drainInboundMedia()
        }
    }

    public func append(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard presentationTime.isValid else {
            return
        }

        inboundMediaLock.withLock {
            inboundMedia.append(.pixelBuffer(pixelBuffer, presentationTime))
        }
        writerQueue.async { [weak self] in
            self?.drainInboundMedia()
        }
    }

    public func finish(
        completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        writerQueue.async { [weak self] in
            guard let self else {
                completionHandler(.success(()))
                return
            }
            self.finishOnWriterQueue(completionHandler: completionHandler)
        }
    }

    public func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        writerQueue.async { [weak self] in
            self?.handleOutputSegmentData(
                segmentData,
                segmentType: segmentType,
                segmentReport: segmentReport
            )
        }
    }

    private func drainInboundMedia() {
        assertOnWriterQueue()
        let media = inboundMediaLock.withLock { () -> [InboundMedia] in
            let media = inboundMedia
            inboundMedia.removeAll(keepingCapacity: true)
            return media
        }
        guard !isFinishing, assetWriter.status != .failed else {
            return
        }
        for item in media {
            switch item {
            case let .sampleBuffer(sampleBuffer, kind):
                switch kind {
                case .video:
                    appendVideo(sampleBuffer)
                case .audio:
                    appendAudio(sampleBuffer)
                }
            case let .pixelBuffer(pixelBuffer, presentationTime):
                appendVideo(pixelBuffer: pixelBuffer, sourcePresentationTime: presentationTime)
            }
        }
    }

    private func handleOutputSegmentData(
        _ segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        assertOnWriterQueue()

        let segment: SegmentedMP4Segment

        switch segmentType {
        case .initialization:
            initializationSegmentCount += 1
            segment = SegmentedMP4Segment(kind: .initialization, data: segmentData)
        case .separable:
            let number = nextSegmentNumber
            nextSegmentNumber += 1
            mediaSegmentCount += 1
            segment = SegmentedMP4Segment(
                kind: .media(number: number),
                data: segmentData,
                durationSeconds: Self.durationSeconds(from: segmentReport)
            )
        @unknown default:
            return
        }

        os_signpost(
            .event,
            log: Self.signpostLog,
            name: "Segment Produced",
            "bytes=%{public}d",
            segmentData.count
        )
        onSegment(segment)
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        assertOnWriterQueue()
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "Append Video Sample", signpostID: signpostID)
        defer {
            os_signpost(.end, log: Self.signpostLog, name: "Append Video Sample", signpostID: signpostID)
        }

        let sourcePresentationTime = sampleBuffer.presentationTimeStamp
        guard sourcePresentationTime.isValid else { return }
        inputVideoSampleCount += 1

        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        if firstInputVideoDescription == nil {
            firstInputVideoDescription = Self.inputVideoDescription(imageBuffer: imageBuffer)
        }
        if pendingVideoFormatDescription == nil {
            pendingVideoFormatDescription = sampleBuffer.formatDescription
        }

        let normalizeSignpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "Normalize Pixel Buffer", signpostID: normalizeSignpostID)
        let maybeNormalizedPixelBuffer = videoPixelBufferNormalizer.normalizedPixelBuffer(from: imageBuffer as CVPixelBuffer)
        os_signpost(.end, log: Self.signpostLog, name: "Normalize Pixel Buffer", signpostID: normalizeSignpostID)
        guard let normalizedPixelBuffer = maybeNormalizedPixelBuffer else {
            recordAppendFailure("The video pixel buffer could not be normalized for AVAssetWriter; \(diagnostics)")
            return
        }

        if firstSourceVideoPresentationTime == nil {
            firstSourceVideoPresentationTime = sourcePresentationTime
            Self.logger.notice(
                "Segmented MP4 writer received first CMSampleBuffer video ptsValue=\(sourcePresentationTime.value, privacy: .public) ptsTimescale=\(sourcePresentationTime.timescale, privacy: .public) ptsFlags=\(sourcePresentationTime.flags.rawValue, privacy: .public) ptsEpoch=\(sourcePresentationTime.epoch, privacy: .public) inputVideoSampleCount=\(self.inputVideoSampleCount, privacy: .public)"
            )
        }
        acceptVideoPixelBuffer(normalizedPixelBuffer, sourcePresentationTime: sourcePresentationTime)
    }

    private func appendVideo(pixelBuffer: CVPixelBuffer, sourcePresentationTime: CMTime) {
        assertOnWriterQueue()
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "Append Program Video", signpostID: signpostID)
        defer {
            os_signpost(.end, log: Self.signpostLog, name: "Append Program Video", signpostID: signpostID)
        }
        inputVideoSampleCount += 1

        if firstInputVideoDescription == nil {
            firstInputVideoDescription = Self.inputVideoDescription(imageBuffer: pixelBuffer)
        }
        if pendingVideoFormatDescription == nil {
            var formatDescription: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            )
            pendingVideoFormatDescription = formatDescription
        }

        if firstSourceVideoPresentationTime == nil {
            firstSourceVideoPresentationTime = sourcePresentationTime
            Self.logger.notice(
                "Segmented MP4 writer received first program video ptsValue=\(sourcePresentationTime.value, privacy: .public) ptsTimescale=\(sourcePresentationTime.timescale, privacy: .public) ptsFlags=\(sourcePresentationTime.flags.rawValue, privacy: .public) ptsEpoch=\(sourcePresentationTime.epoch, privacy: .public) inputVideoSampleCount=\(self.inputVideoSampleCount, privacy: .public)"
            )
        }
        acceptVideoPixelBuffer(pixelBuffer, sourcePresentationTime: sourcePresentationTime)
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        assertOnWriterQueue()
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "Append Audio Sample", signpostID: signpostID)
        defer {
            os_signpost(.end, log: Self.signpostLog, name: "Append Audio Sample", signpostID: signpostID)
        }

        if firstInputAudioDescription == nil {
            firstInputAudioDescription = Self.inputAudioDescription(sampleBuffer: sampleBuffer)
        }
        inputAudioSampleCount += 1
        if pendingAudioFormatDescription == nil {
            pendingAudioFormatDescription = sampleBuffer.formatDescription
        }
        let sourcePresentationTime = sampleBuffer.presentationTimeStamp
        if sourcePresentationTime.isValid, firstSourceAudioPresentationTime == nil {
            firstSourceAudioPresentationTime = sourcePresentationTime
            Self.logger.notice(
                "Segmented MP4 writer received first audio ptsValue=\(sourcePresentationTime.value, privacy: .public) ptsTimescale=\(sourcePresentationTime.timescale, privacy: .public) ptsFlags=\(sourcePresentationTime.flags.rawValue, privacy: .public) ptsEpoch=\(sourcePresentationTime.epoch, privacy: .public) inputAudioSampleCount=\(self.inputAudioSampleCount, privacy: .public)"
            )
        }

        guard assetWriter.status != .unknown else {
            if shouldAppendAudioSampleBuffer(sampleBuffer) {
                pendingAudioSampleBuffers.append(sampleBuffer)
            }
            startWritingIfPossible()
            return
        }

        guard shouldAppendAudioSampleBuffer(sampleBuffer) else {
            return
        }

        appendAudioSampleBuffer(sampleBuffer)
    }

    private func acceptVideoPixelBuffer(_ imageBuffer: CVImageBuffer, sourcePresentationTime: CMTime) {
        assertOnWriterQueue()

        if let lastAcceptedVideoPresentationTime,
           CMTimeCompare(sourcePresentationTime, lastAcceptedVideoPresentationTime) <= 0 {
            droppedNonMonotonicVideoFrameCount += 1
            if droppedNonMonotonicVideoFrameCount == 1 ||
                droppedNonMonotonicVideoFrameCount.isMultiple(of: 120) {
                Self.logger.error(
                    "Segmented MP4 writer dropped non-monotonic video pts droppedNonMonotonicVideoFrameCount=\(self.droppedNonMonotonicVideoFrameCount, privacy: .public) sourcePTS=\(Self.timeDescription(sourcePresentationTime), privacy: .public) lastAcceptedVideoPTS=\(Self.timeDescription(lastAcceptedVideoPresentationTime), privacy: .public)"
                )
            }
            return
        }
        lastAcceptedVideoPresentationTime = sourcePresentationTime
        encodedVideoFrameCount += 1

        appendAcceptedVideoPixelBuffer(imageBuffer, sourcePresentationTime: sourcePresentationTime)
    }

    private func appendAcceptedVideoPixelBuffer(_ imageBuffer: CVImageBuffer, sourcePresentationTime: CMTime) {
        assertOnWriterQueue()

        let pixelBuffer = imageBuffer as CVPixelBuffer
        if assetWriter.status == .unknown {
            pendingVideoPixelBuffers.append(PendingVideoPixelBuffer(
                pixelBuffer: pixelBuffer,
                sourcePresentationTime: sourcePresentationTime
            ))
            startWritingIfPossible()
            return
        }

        guard assetWriter.status == .writing else {
            return
        }
        if !pendingVideoPixelBuffers.isEmpty {
            waitedVideoReceiverFrameCount += 1
            if waitedVideoReceiverFrameCount == 1 ||
                waitedVideoReceiverFrameCount.isMultiple(of: 120) {
                Self.logger.notice(
                    "Segmented MP4 writer queued video for receiver backpressure waitedVideoReceiverFrameCount=\(self.waitedVideoReceiverFrameCount, privacy: .public) pendingVideoFrameCount=\(self.pendingVideoPixelBuffers.count + 1, privacy: .public) encodedVideoFrameCount=\(self.encodedVideoFrameCount, privacy: .public) appendedVideoFrameCount=\(self.appendedVideoFrameCount, privacy: .public) assetWriterStatus=\(self.assetWriter.status.rawValue, privacy: .public)"
                )
            }
        }
        pendingVideoPixelBuffers.append(PendingVideoPixelBuffer(
            pixelBuffer: pixelBuffer,
            sourcePresentationTime: sourcePresentationTime
        ))
        drainPendingVideoPixelBuffers()
    }

    private func startWritingIfPossible() {
        assertOnWriterQueue()

        guard assetWriter.status == .unknown else {
            return
        }
        guard let videoFormatDescription = pendingVideoFormatDescription,
              let audioFormatDescription = pendingAudioFormatDescription,
              let sourcePresentationOrigin else {
            return
        }
        Self.logger.notice(
            "Segmented MP4 writer starting pendingVideo=\(self.pendingVideoPixelBuffers.count, privacy: .public) pendingAudio=\(self.pendingAudioSampleBuffers.count, privacy: .public) encodedVideoFrameCount=\(self.encodedVideoFrameCount, privacy: .public) appendedVideoFrameCount=\(self.appendedVideoFrameCount, privacy: .public) appendedAudioBufferCount=\(self.appendedAudioBufferCount, privacy: .public)"
        )
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "AssetWriter Start", signpostID: signpostID)
        defer {
            os_signpost(.end, log: Self.signpostLog, name: "AssetWriter Start", signpostID: signpostID)
        }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoOutputSettings(configuration: configuration),
            sourceFormatHint: videoFormatDescription
        )
        videoInput.expectsMediaDataInRealTime = true
        videoInput.mediaDataLocation = .interleavedWithMainMediaData
        videoInput.preferredMediaChunkDuration = CMTime(
            seconds: Double(configuration.segmentDurationSeconds),
            preferredTimescale: outputTimescale
        )
        guard assetWriter.canAdd(videoInput) else {
            recordAppendFailure(Self.videoInputPreflightFailureDescription(
                assetWriter: assetWriter,
                videoFormatDescription: videoFormatDescription,
                configuration: configuration,
                diagnostics: diagnostics
            ))
            return
        }
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: Self.audioOutputSettings(configuration: configuration),
            sourceFormatHint: audioFormatDescription
        )
        audioInput.expectsMediaDataInRealTime = true
        audioInput.mediaDataLocation = .interleavedWithMainMediaData
        audioInput.preferredMediaChunkDuration = CMTime(
            seconds: Double(configuration.segmentDurationSeconds),
            preferredTimescale: CMTimeScale(configuration.audioSampleRate)
        )
        guard assetWriter.canAdd(audioInput) else {
            recordAppendFailure(Self.audioInputPreflightFailureDescription(
                assetWriter: assetWriter,
                configuration: configuration,
                diagnostics: diagnostics
            ))
            return
        }
        self.videoInput = videoInput
        self.audioInput = audioInput
        assetWriter.add(videoInput)
        assetWriter.add(audioInput)
        videoPixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: nil
        )
        assetWriter.initialSegmentStartTime = .zero

        do {
            try assetWriter.start()
        } catch {
            recordAppendFailure(Self.failureDescription(error: error, diagnostics: diagnostics))
            return
        }
        guard assetWriter.status == .writing else {
            recordAppendFailure(Self.failureDescription(error: assetWriter.error, diagnostics: currentDiagnostics()))
            return
        }
        Self.logger.notice(
            "Segmented MP4 writer started encodedVideoFrameCount=\(self.encodedVideoFrameCount, privacy: .public) appendedVideoFrameCount=\(self.appendedVideoFrameCount, privacy: .public) appendedAudioBufferCount=\(self.appendedAudioBufferCount, privacy: .public) sourcePresentationOriginValue=\(sourcePresentationOrigin.value, privacy: .public) sourcePresentationOriginTimescale=\(sourcePresentationOrigin.timescale, privacy: .public) sourcePresentationOriginFlags=\(sourcePresentationOrigin.flags.rawValue, privacy: .public) sourcePresentationOriginEpoch=\(sourcePresentationOrigin.epoch, privacy: .public)"
        )
        assetWriter.startSession(atSourceTime: .zero)
        hasStartedSession = true

        videoInput.requestMediaDataWhenReady(on: writerQueue) { [weak self] in
            self?.drainPendingVideoPixelBuffers()
            self?.finishWhenPendingMediaIsDrained()
        }
        audioInput.requestMediaDataWhenReady(on: writerQueue) { [weak self] in
            self?.drainPendingAudioSampleBuffers()
            self?.finishWhenPendingMediaIsDrained()
        }

        drainPendingVideoPixelBuffers()
        drainPendingAudioSampleBuffers()
    }

    private func finishOnWriterQueue(
        completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        assertOnWriterQueue()
        drainInboundMedia()
        isFinishing = true
        pendingFinishHandler = completionHandler
        finishWhenPendingMediaIsDrained()
    }

    private func finishWhenPendingMediaIsDrained() {
        assertOnWriterQueue()
        guard let completionHandler = pendingFinishHandler else { return }
        if assetWriter.status == .writing {
            drainPendingVideoPixelBuffers()
            drainPendingAudioSampleBuffers()
            guard pendingVideoPixelBuffers.isEmpty,
                  pendingAudioSampleBuffers.isEmpty else {
                return
            }
        }
        pendingFinishHandler = nil
        finishAssetWriter(completionHandler: completionHandler)
    }

    private func finishAssetWriter(
        completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        assertOnWriterQueue()
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "AssetWriter Finish", signpostID: signpostID)

        guard assetWriter.status == .writing || assetWriter.status == .unknown else {
            os_signpost(.end, log: Self.signpostLog, name: "AssetWriter Finish", signpostID: signpostID)
            if assetWriter.status == .failed {
                completionHandler(.failure(SegmentedMP4WriterError.writerFailed(
                    Self.failureDescription(
                        error: assetWriter.error,
                        diagnostics: currentDiagnostics(),
                        appendFailureDescription: appendFailureDescription
                    )
                )))
                return
            }
            completionHandler(.success(()))
            return
        }

        guard assetWriter.status == .writing else {
            os_signpost(.end, log: Self.signpostLog, name: "AssetWriter Finish", signpostID: signpostID)
            if let appendFailureDescription {
                completionHandler(.failure(SegmentedMP4WriterError.writerFailed(appendFailureDescription)))
                return
            }
            let description = "The segmented MP4 writer never started before finish; \(currentDiagnostics()); pendingVideoPixelBuffers=\(pendingVideoPixelBuffers.count); pendingAudioSampleBuffers=\(pendingAudioSampleBuffers.count); hasVideoFormat=\(pendingVideoFormatDescription != nil); hasAudioFormat=\(pendingAudioFormatDescription != nil)"
            recordAppendFailure(description)
            assetWriter.cancelWriting()
            completionHandler(.failure(SegmentedMP4WriterError.writerFailed(description)))
            return
        }

        guard appendedAudioBufferCount > 0 else {
            os_signpost(.end, log: Self.signpostLog, name: "AssetWriter Finish", signpostID: signpostID)
            let description = "The segmented MP4 writer did not receive any normalized audio buffers before finish; \(currentDiagnostics())"
            recordAppendFailure(description)
            assetWriter.cancelWriting()
            completionHandler(.failure(SegmentedMP4WriterError.writerFailed(description)))
            return
        }

        guard appendedVideoFrameCount > 0 else {
            os_signpost(.end, log: Self.signpostLog, name: "AssetWriter Finish", signpostID: signpostID)
            let description = "The segmented MP4 writer did not append any video frames before finish; \(currentDiagnostics())"
            recordAppendFailure(description)
            assetWriter.cancelWriting()
            completionHandler(.failure(SegmentedMP4WriterError.writerFailed(description)))
            return
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        assetWriter.finishWriting { [weak self] in
            guard let self else {
                os_signpost(.end, log: Self.signpostLog, name: "AssetWriter Finish", signpostID: signpostID)
                completionHandler(.success(()))
                return
            }
            self.writerQueue.async {
                os_signpost(.end, log: Self.signpostLog, name: "AssetWriter Finish", signpostID: signpostID)
                if self.assetWriter.status == .failed {
                    completionHandler(.failure(SegmentedMP4WriterError.writerFailed(
                        Self.failureDescription(
                            error: self.assetWriter.error,
                            diagnostics: self.currentDiagnostics(),
                            appendFailureDescription: self.appendFailureDescription
                        )
                    )))
                } else {
                    completionHandler(.success(()))
                }
            }
        }
    }

    private func assertOnWriterQueue() {
        dispatchPrecondition(condition: .onQueue(writerQueue))
    }

    private func currentDiagnostics() -> String {
        [
            diagnostics,
            "encodedVideoFrameCount=\(encodedVideoFrameCount)",
            "appendedVideoFrameCount=\(appendedVideoFrameCount)",
            "appendedAudioBufferCount=\(appendedAudioBufferCount)",
            "initializationSegmentCount=\(initializationSegmentCount)",
            "mediaSegmentCount=\(mediaSegmentCount)",
            "waitedVideoReceiverFrameCount=\(waitedVideoReceiverFrameCount)",
            "waitedAudioReceiverBufferCount=\(waitedAudioReceiverBufferCount)",
            "pendingVideoPixelBufferCount=\(pendingVideoPixelBuffers.count)",
            "pendingAudioSampleBufferCount=\(pendingAudioSampleBuffers.count)",
            "droppedNonMonotonicVideoFrameCount=\(droppedNonMonotonicVideoFrameCount)",
            "droppedPreRollAudioBufferCount=\(droppedPreRollAudioBufferCount)",
            "sourcePresentationOrigin=\(Self.timeDescription(sourcePresentationOrigin))",
            "initialSegmentStartTime=\(Self.timeDescription(assetWriter.initialSegmentStartTime))",
            "firstSourceVideoPTS=\(Self.timeDescription(firstSourceVideoPresentationTime))",
            "firstSourceAudioPTS=\(Self.timeDescription(firstSourceAudioPresentationTime))",
            "firstInputVideo=\(firstInputVideoDescription ?? "nil")",
            "firstInputAudio=\(firstInputAudioDescription ?? "nil")",
            "assetWriterStatus=\(assetWriter.status.rawValue)"
        ].joined(separator: "; ")
    }

    private func recordAppendFailure(_ description: String) {
        appendFailureDescription = description
        Self.logger.error(
            "Segmented MP4 writer append/start failed assetWriterStatus=\(self.assetWriter.status.rawValue, privacy: .public) encodedVideoFrameCount=\(self.encodedVideoFrameCount, privacy: .public) appendedVideoFrameCount=\(self.appendedVideoFrameCount, privacy: .public) appendedAudioBufferCount=\(self.appendedAudioBufferCount, privacy: .public) initializationSegmentCount=\(self.initializationSegmentCount, privacy: .public) mediaSegmentCount=\(self.mediaSegmentCount, privacy: .public) waitedVideoReceiverFrameCount=\(self.waitedVideoReceiverFrameCount, privacy: .public) waitedAudioReceiverBufferCount=\(self.waitedAudioReceiverBufferCount, privacy: .public) droppedNonMonotonicVideoFrameCount=\(self.droppedNonMonotonicVideoFrameCount, privacy: .public) droppedPreRollAudioBufferCount=\(self.droppedPreRollAudioBufferCount, privacy: .public) description=\(description, privacy: .public)"
        )
    }

    private var sourcePresentationOrigin: CMTime? {
        firstSourceVideoPresentationTime
    }

    private static func durationSeconds(from segmentReport: AVAssetSegmentReport?) -> Double? {
        segmentReport?.trackReports
            .map(\.duration.seconds)
            .filter { $0.isFinite && $0 > 0 }
            .max()
    }

    private static func timeDescription(_ time: CMTime?) -> String {
        guard let time else { return "nil" }
        return timeDescription(time)
    }

    private static func timeDescription(_ time: CMTime) -> String {
        "value=\(time.value)/timescale=\(time.timescale)/flags=\(time.flags.rawValue)/epoch=\(time.epoch)"
    }

    private static func diagnostics(
        configuration: SegmentedMP4WriterConfiguration,
        temporaryDirectory: URL,
        assetWriter: AVAssetWriter
    ) -> String {
        let fileManager = FileManager.default
        let temporaryPath = temporaryDirectory.path
        let temporaryDirectoryExists = fileManager.fileExists(atPath: temporaryPath)
        let temporaryDirectoryWritable = fileManager.isWritableFile(atPath: temporaryPath)

        return [
            "configuration=\(configuration.diagnosticDescription)",
            "temporaryDirectory=\(temporaryPath)",
            "temporaryDirectoryExists=\(temporaryDirectoryExists)",
            "temporaryDirectoryWritable=\(temporaryDirectoryWritable)",
            "availableMediaTypes=\(Self.mediaTypesDescription(assetWriter.availableMediaTypes))",
            "canApplyVideoH264=\(assetWriter.canApply(outputSettings: Self.videoOutputSettings(configuration: configuration), forMediaType: .video))",
            "canApplyAudioAAC=\(assetWriter.canApply(outputSettings: Self.audioOutputSettings(configuration: configuration), forMediaType: .audio))",
            "movieTimeScale=\(assetWriter.movieTimeScale)",
            "segmentInterval=\(configuration.segmentDurationSeconds)s",
            "videoPixelBufferPoolMinimumBufferCount=\(configuration.videoPixelBufferPoolMinimumBufferCount)",
            "producesCombinableFragments=\(assetWriter.producesCombinableFragments)",
            "outputFileTypeProfile=\(assetWriter.outputFileTypeProfile?.rawValue ?? "nil")",
            "videoInputMode=avassetwriter-pixelbuffer-h264",
            "audioInputMode=avassetwriter-aac"
        ].joined(separator: "; ")
    }

    private static func inputVideoDescription(imageBuffer: CVImageBuffer) -> String {
        let pixelBuffer = imageBuffer as CVPixelBuffer
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        return "width=\(width),height=\(height),pixelFormat=\(pixelFormat),planes=\(planeCount)"
    }

    private func shouldAppendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { return false }
        guard sourcePresentationOrigin != nil else { return false }

        let sourcePresentationTime = sampleBuffer.presentationTimeStamp
        guard sourcePresentationTime.isValid else { return false }
        guard let sourcePresentationOrigin else { return false }
        let elapsed = CMTimeSubtract(sourcePresentationTime, sourcePresentationOrigin)
        guard elapsed.seconds.isFinite else { return false }
        if CMTimeCompare(elapsed, .zero) < 0 {
            droppedPreRollAudioBufferCount += 1
            return false
        }
        return true
    }

    private func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        assertOnWriterQueue()

        guard assetWriter.status == .writing else {
            return
        }
        if !pendingAudioSampleBuffers.isEmpty {
            waitedAudioReceiverBufferCount += 1
            if waitedAudioReceiverBufferCount == 1 ||
                waitedAudioReceiverBufferCount.isMultiple(of: 120) {
                Self.logger.notice(
                    "Segmented MP4 writer queued audio for receiver backpressure waitedAudioReceiverBufferCount=\(self.waitedAudioReceiverBufferCount, privacy: .public) pendingAudioBufferCount=\(self.pendingAudioSampleBuffers.count + 1, privacy: .public) inputAudioSampleCount=\(self.inputAudioSampleCount, privacy: .public) appendedAudioBufferCount=\(self.appendedAudioBufferCount, privacy: .public) assetWriterStatus=\(self.assetWriter.status.rawValue, privacy: .public)"
                )
            }
        }
        pendingAudioSampleBuffers.append(sampleBuffer)
        drainPendingAudioSampleBuffers()
    }

    private func writerPresentationTime(for sourcePresentationTime: CMTime) -> CMTime? {
        guard let sourcePresentationOrigin else { return nil }
        let writerPresentationTime = CMTimeSubtract(sourcePresentationTime, sourcePresentationOrigin)
        guard writerPresentationTime.isValid,
              writerPresentationTime.seconds.isFinite else {
            recordAppendFailure(
                "The segmented MP4 writer could not map source PTS to writer PTS; sourcePTS=\(Self.timeDescription(sourcePresentationTime)); sourcePresentationOrigin=\(Self.timeDescription(sourcePresentationOrigin)); \(currentDiagnostics())"
            )
            return nil
        }
        return writerPresentationTime
    }

    private func retimedAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let sourcePresentationOrigin else { return nil }

        var timingEntryCount: CMItemCount = 0
        let countStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingEntryCount
        )
        guard countStatus == noErr, timingEntryCount > 0 else {
            recordAppendFailure(
                "The segmented MP4 writer could not read audio timing entries status=\(countStatus); \(currentDiagnostics())"
            )
            return nil
        }

        var timing = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: timingEntryCount
        )
        let timingStatus = timing.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetSampleTimingInfoArray(
                sampleBuffer,
                entryCount: timingEntryCount,
                arrayToFill: buffer.baseAddress,
                entriesNeededOut: nil
            )
        }
        guard timingStatus == noErr else {
            recordAppendFailure(
                "The segmented MP4 writer could not copy audio timing entries status=\(timingStatus); \(currentDiagnostics())"
            )
            return nil
        }

        for index in timing.indices {
            let presentationTime = timing[index].presentationTimeStamp
            if presentationTime.isValid {
                timing[index].presentationTimeStamp = CMTimeSubtract(presentationTime, sourcePresentationOrigin)
            }
            let decodeTime = timing[index].decodeTimeStamp
            if decodeTime.isValid {
                timing[index].decodeTimeStamp = CMTimeSubtract(decodeTime, sourcePresentationOrigin)
            }
        }

        var retimedSampleBuffer: CMSampleBuffer?
        let copyStatus = timing.withUnsafeBufferPointer { buffer in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: timingEntryCount,
                sampleTimingArray: buffer.baseAddress,
                sampleBufferOut: &retimedSampleBuffer
            )
        }
        guard copyStatus == noErr, let retimedSampleBuffer else {
            recordAppendFailure(
                "The segmented MP4 writer could not create retimed audio sample buffer status=\(copyStatus); \(currentDiagnostics())"
            )
            return nil
        }
        return retimedSampleBuffer
    }

    private func drainPendingVideoPixelBuffers() {
        assertOnWriterQueue()
        guard assetWriter.status == .writing,
              let videoInput,
              let videoPixelBufferAdaptor else {
            return
        }
        while videoInput.isReadyForMoreMediaData,
              !pendingVideoPixelBuffers.isEmpty {
            let frame = pendingVideoPixelBuffers.removeFirst()
            guard let presentationTime = writerPresentationTime(for: frame.sourcePresentationTime) else {
                continue
            }
            if videoPixelBufferAdaptor.append(frame.pixelBuffer, withPresentationTime: presentationTime) {
                appendedVideoFrameCount += 1
            } else {
                recordAppendFailure(Self.failureDescription(
                    error: assetWriter.error,
                    diagnostics: currentDiagnostics()
                ))
                break
            }
        }
    }

    private func drainPendingAudioSampleBuffers() {
        assertOnWriterQueue()
        guard assetWriter.status == .writing,
              let audioInput else {
            return
        }
        while audioInput.isReadyForMoreMediaData,
              !pendingAudioSampleBuffers.isEmpty {
            let sampleBuffer = pendingAudioSampleBuffers.removeFirst()
            guard shouldAppendAudioSampleBuffer(sampleBuffer),
                  let writerSampleBuffer = retimedAudioSampleBuffer(sampleBuffer) else {
                continue
            }
            if audioInput.append(writerSampleBuffer) {
                appendedAudioBufferCount += 1
            } else {
                recordAppendFailure(Self.failureDescription(
                    error: assetWriter.error,
                    diagnostics: currentDiagnostics()
                ))
                break
            }
        }
    }

    private static func audioOutputSettings(configuration: SegmentedMP4WriterConfiguration) -> [String: Any] {
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: configuration.audioSampleRate,
            AVNumberOfChannelsKey: configuration.audioChannelCount,
            AVEncoderBitRateKey: configuration.audioBitRate
        ]
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

    private static func pixelBufferAttributes(configuration: SegmentedMP4WriterConfiguration) -> CVPixelBufferCreationAttributes {
        CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            size: CVImageSize(width: configuration.width, height: configuration.height)
        )
    }

    private static func inputAudioDescription(sampleBuffer: CMSampleBuffer) -> String {
        guard let formatDescription = sampleBuffer.formatDescription else {
            return "formatDescription=nil"
        }
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let presentationTime = sampleBuffer.presentationTimeStamp
        let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription)
        let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        let streamSummary = streamDescription.map {
            [
                "formatID=\(fourCC($0.mFormatID))",
                "formatFlags=\($0.mFormatFlags)",
                "sampleRate=\($0.mSampleRate)",
                "channels=\($0.mChannelsPerFrame)",
                "bitsPerChannel=\($0.mBitsPerChannel)",
                "bytesPerFrame=\($0.mBytesPerFrame)",
                "framesPerPacket=\($0.mFramesPerPacket)",
                "bytesPerPacket=\($0.mBytesPerPacket)"
            ].joined(separator: ",")
        } ?? "streamDescription=nil"
        return [
            "mediaSubType=\(fourCC(mediaSubType))",
            "sampleCount=\(sampleCount)",
            "pts=\(presentationTime.seconds)",
            streamSummary
        ].joined(separator: ",")
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let scalarValues = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        let scalars = scalarValues.map { byte -> UnicodeScalar in
            if byte >= 32 && byte <= 126, let scalar = UnicodeScalar(Int(byte)) {
                return scalar
            }
            return "."
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func preflight(
        assetWriter: AVAssetWriter,
        configuration: SegmentedMP4WriterConfiguration,
        requiredMediaTypes: [AVMediaType]
    ) throws {
        for mediaType in requiredMediaTypes {
            guard assetWriter.availableMediaTypes.contains(mediaType) else {
                throw SegmentedMP4WriterError.preflightFailed(
                    "\(mediaType.rawValue) is not in availableMediaTypes=\(mediaTypesDescription(assetWriter.availableMediaTypes))"
                )
            }

            let outputSettings: [String: Any]? = switch mediaType {
            case .video:
                videoOutputSettings(configuration: configuration)
            case .audio:
                audioOutputSettings(configuration: configuration)
            default:
                nil
            }
            guard assetWriter.canApply(
                outputSettings: outputSettings,
                forMediaType: mediaType
            ) else {
                throw SegmentedMP4WriterError.preflightFailed(
                    "canApply(outputSettings:) failed for \(mediaType.rawValue); availableMediaTypes=\(mediaTypesDescription(assetWriter.availableMediaTypes))"
                )
            }
        }
    }

    private static func videoInputPreflightFailureDescription(
        assetWriter: AVAssetWriter,
        videoFormatDescription: CMFormatDescription,
        configuration: SegmentedMP4WriterConfiguration,
        diagnostics: String
    ) -> String {
        [
            "canAdd(videoInput) failed before startWriting",
            "videoFormatDescription=\(CMFormatDescriptionGetMediaSubType(videoFormatDescription))",
            "availableMediaTypes=\(mediaTypesDescription(assetWriter.availableMediaTypes))",
            "canApplyVideoH264=\(assetWriter.canApply(outputSettings: videoOutputSettings(configuration: configuration), forMediaType: .video))",
            diagnostics
        ].joined(separator: "; ")
    }

    private static func audioInputPreflightFailureDescription(
        assetWriter: AVAssetWriter,
        configuration: SegmentedMP4WriterConfiguration,
        diagnostics: String
    ) -> String {
        [
            "canAdd(audioInput) failed before startWriting",
            "availableMediaTypes=\(mediaTypesDescription(assetWriter.availableMediaTypes))",
            "canApplyAudioAAC=\(assetWriter.canApply(outputSettings: audioOutputSettings(configuration: configuration), forMediaType: .audio))",
            diagnostics
        ].joined(separator: "; ")
    }

    private static func mediaTypesDescription(_ mediaTypes: [AVMediaType]) -> String {
        "[" + mediaTypes.map(\.rawValue).joined(separator: ",") + "]"
    }

    private static func failureDescription(
        error: Error?,
        diagnostics: String,
        appendFailureDescription: String? = nil
    ) -> String {
        let nsError = error as NSError?
        let base = nsError?.localizedDescription ?? "Unknown error"
        let failureReason = nsError?.localizedFailureReason.map { " failureReason=\($0)" } ?? ""
        let recoverySuggestion = nsError?.localizedRecoverySuggestion.map { " recoverySuggestion=\($0)" } ?? ""
        let underlying = (nsError?.userInfo[NSUnderlyingErrorKey] as? NSError).map {
            " underlying=\($0.domain)(\($0.code)): \($0.localizedDescription)"
        } ?? ""
        let appendFailure = appendFailureDescription.map { " appendFailure=\($0)" } ?? ""
        return "\(base)\(failureReason)\(recoverySuggestion)\(underlying)\(appendFailure); \(diagnostics)"
    }
}

private enum InboundMedia {
    case sampleBuffer(CMSampleBuffer, SegmentedMP4SampleKind)
    case pixelBuffer(CVPixelBuffer, CMTime)
}

private struct PendingVideoPixelBuffer {
    let pixelBuffer: CVPixelBuffer
    let sourcePresentationTime: CMTime
}

private extension SegmentedMP4WriterConfiguration {
    var diagnosticDescription: String {
        "width=\(width), height=\(height), frameRate=\(frameRate), videoBitRate=\(videoBitRate), videoPixelBufferPoolMinimumBufferCount=\(videoPixelBufferPoolMinimumBufferCount), audioSampleRate=\(audioSampleRate), audioChannelCount=\(audioChannelCount), audioBitRate=\(audioBitRate), segmentDurationSeconds=\(segmentDurationSeconds), timescale=\(timescale), startNumber=\(startNumber)"
    }
}
